<#
  RAM Manager - frees RAM by closing background apps you aren't using.
  It LEARNS your habits (which apps you use, on which days and hours, and
  which closings you didn't like) and hands that profile to TypeSafe Jev
  (via OpenRouter), which makes the keep/close call.

  Usage (from this folder, in PowerShell):
    .\ram setkey          Save your OpenRouter API key (asks securely)
    .\ram status          Show managed apps and how much RAM they use
    .\ram stats           Show what it has learned about your usage
    .\ram decide          Ask Jev what to close - DRY RUN, changes nothing
    .\ram run             Ask Jev, then close apps (asks you when unsure)
    .\ram watch           Keep running: learn your usage, decide every N minutes
    .\ram autostart on|off   Run 'watch' hidden every time you log in
    .\ram mode light|work|normal   Rule-based: stop/start a fixed set of apps
    .\ram restore         Reopen everything this tool closed
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Name
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$DataDir  = Join-Path $Root 'data'
$DataPath = Join-Path $DataDir 'usage.json'
$LogPath  = Join-Path $DataDir 'decisions.log'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

$ConfigPath = Join-Path $Root 'config.json'
if (-not (Test-Path $ConfigPath)) { Copy-Item (Join-Path $Root 'config.example.json') $ConfigPath }
$Config =Get-Content $ConfigPath -Raw | ConvertFrom-Json

function Save-Config {
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8
}

$AutostartLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'RAM Manager (watch).lnk'
function Test-Autostart { Test-Path $AutostartLink }
function Set-Autostart([bool]$On) {
    if (-not $On) { if (Test-Path $AutostartLink) { Remove-Item $AutostartLink }; return }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($AutostartLink)
    $s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'ram-manager.ps1')`" watch"
    $s.WorkingDirectory = $Root
    $s.Save()
}

# How long after the tool closes an app a reopen counts as "that was a mistake".
$ReopenWindowMinutes = 30

# ================================================================ helpers

Add-Type -ErrorAction SilentlyContinue @"
using System;
using System.Runtime.InteropServices;
public static class RamMgrWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@

function Get-ForegroundProcessName {
    try {
        $h = [RamMgrWin32]::GetForegroundWindow()
        $procId = [uint32]0
        [void][RamMgrWin32]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($procId -eq 0) { return $null }
        return (Get-Process -Id $procId -ErrorAction Stop).Name
    } catch { return $null }
}

function Write-Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Get-RamInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = $os.TotalVisibleMemorySize / 1MB
    $free  = $os.FreePhysicalMemory / 1MB
    [pscustomobject]@{
        totalGB     = [math]::Round($total, 1)
        availableGB = [math]::Round($free, 1)
        usedPercent = [math]::Round((1 - $free / $total) * 100)
    }
}

function Get-AppMemoryMB($app) {
    $procs = Get-Process -Name $app.process -ErrorAction SilentlyContinue
    if (-not $procs) { return 0 }
    return [math]::Round((($procs | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
}

function Test-AppRunning($app) {
    if ($app.kind -eq 'service') {
        $svc = Get-Service -Name $app.service -ErrorAction SilentlyContinue
        return ($svc -and $svc.Status -eq 'Running')
    }
    return [bool](Get-Process -Name $app.process -ErrorAction SilentlyContinue)
}

function Get-App([string]$id) {
    $a = $Config.apps | Where-Object { $_.id -eq $id }
    if (-not $a) { throw "Unknown app id '$id' (check config.json)" }
    return $a
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Total CPU seconds used so far by all processes with this name (works without admin).
function Get-ProcessCpuSeconds([string]$procName) {
    $rows = Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "Name = '$procName' OR Name LIKE '$procName#%'" -ErrorAction SilentlyContinue
    if (-not $rows) { return $null }
    return (($rows | Measure-Object PercentProcessorTime -Sum).Sum) / 1e7
}

# ================================================================ learned data (data\usage.json)

function ConvertTo-Hash($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }; return $h
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
        return , @($o | ForEach-Object { ConvertTo-Hash $_ })
    }
    return $o
}

function Load-Data {
    $d = @{
        slotTotals  = @{}   # "Tue-20" -> samples taken in that weekday+hour
        trackedDays = @{}   # "2026-11-17" -> 1
        apps        = @{}   # id -> usage + feedback
        recent      = @()   # last 60 min of foreground samples
        closed      = @{}   # id -> when the tool closed it (for reopen detection)
        closedByTool = @()  # ids to bring back with 'restore'
    }
    if (Test-Path $DataPath) {
        try {
            $j = ConvertTo-Hash (Get-Content $DataPath -Raw | ConvertFrom-Json)
            foreach ($k in @($d.Keys)) { if ($j.ContainsKey($k) -and $null -ne $j[$k]) { $d[$k] = $j[$k] } }
        } catch { Write-Warning "usage.json unreadable, starting fresh: $($_.Exception.Message)" }
    }
    $d.recent = @($d.recent); $d.closedByTool = @($d.closedByTool)
    foreach ($a in $Config.apps) { Initialize-AppEntry $d $a.id }
    return $d
}

function Initialize-AppEntry($d, [string]$id) {
    if (-not $d.apps.ContainsKey($id)) {
        $d.apps[$id] = @{ slots = @{}; days = @{}; lastUsed = $null; reopened = 0; rejected = 0; accepted = 0 }
    }
    $e = $d.apps[$id]
    foreach ($k in 'slots', 'days') { if (-not $e[$k]) { $e[$k] = @{} } }
    foreach ($k in 'reopened', 'rejected', 'accepted') { if ($null -eq $e[$k]) { $e[$k] = 0 } }
}

function Save-Data($d) {
    $tmp = "$DataPath.tmp"
    $d | ConvertTo-Json -Depth 8 -Compress | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $DataPath -Force
}

function Get-SlotKey([datetime]$t) { "{0}-{1:00}" -f $t.DayOfWeek.ToString().Substring(0, 3), $t.Hour }

# One learning sample: who is in front, which managed apps are active, and
# whether something the tool closed got reopened (= the tool was wrong).
function Add-UsageSample($d, $cpuPrev) {
    $now = Get-Date
    $key = Get-SlotKey $now
    $day = $now.ToString('yyyy-MM-dd')
    $fg  = Get-ForegroundProcessName

    $d.slotTotals[$key] = 1 + [int]$d.slotTotals[$key]
    $d.trackedDays[$day] = 1

    $cutoff = $now.AddMinutes(-60)
    $d.recent = @($d.recent | Where-Object { [datetime]$_.t -gt $cutoff })
    if ($fg) { $d.recent += @{ t = $now.ToString('o'); app = $fg } }

    foreach ($a in $Config.apps) {
        $e = $d.apps[$a.id]
        $used = ($fg -and $a.process -eq $fg)
        if ($a.activityByCpu -and $null -ne $cpuPrev) {
            $cpu = Get-ProcessCpuSeconds $a.process
            if ($null -ne $cpu -and $cpuPrev.ContainsKey($a.id) -and ($cpu - $cpuPrev[$a.id]) -ge [double]$a.activityByCpu) { $used = $true }
            if ($null -ne $cpu) { $cpuPrev[$a.id] = $cpu }
        }
        if ($used) {
            $e.slots[$key] = 1 + [int]$e.slots[$key]
            $e.days[$day] = 1
            $e.lastUsed = $now.ToString('o')
        }
    }

    foreach ($id in @($d.closed.Keys)) {
        $mins = ($now - [datetime]$d.closed[$id]).TotalMinutes
        if (Test-AppRunning (Get-App $id)) {
            if ($mins -le $ReopenWindowMinutes) {
                $d.apps[$id].reopened++
                Write-Log ("LEARN {0} was reopened {1:N0} min after being closed - will be more careful with it" -f $id, $mins)
            }
            $d.closed.Remove($id)
            $d.closedByTool = @($d.closedByTool | Where-Object { $_ -ne $id })
        } elseif ($mins -gt $ReopenWindowMinutes) {
            $d.closed.Remove($id)
        }
    }
}

function Get-Percent($num, $den) { if ($den -gt 0) { [math]::Round(100.0 * $num / $den) } else { $null } }

# What we've learned about one app, in plain numbers Jev can weigh.
function Get-LearnedProfile($d, $app) {
    $now = Get-Date
    $e = $d.apps[$app.id]
    $keyNow  = Get-SlotKey $now
    $keyNext = Get-SlotKey $now.AddHours(1)
    $hh = '-{0:00}' -f $now.Hour

    $anyDayUsed = 0; $anyDayTotal = 0
    foreach ($k in $d.slotTotals.Keys) {
        if ($k.EndsWith($hh)) { $anyDayTotal += [int]$d.slotTotals[$k]; $anyDayUsed += [int]$e.slots[$k] }
    }
    $mins = if ($e.lastUsed) { [math]::Round(($now - [datetime]$e.lastUsed).TotalMinutes) } else { $null }

    [ordered]@{
        percentOfTrackedDaysUsed            = Get-Percent $e.days.Count $d.trackedDays.Count
        usedAtThisWeekdayAndHourPercent     = Get-Percent ([int]$e.slots[$keyNow]) ([int]$d.slotTotals[$keyNow])
        usedAtThisHourOnAnyDayPercent       = Get-Percent $anyDayUsed $anyDayTotal
        usedInTheNextHourPercent            = Get-Percent ([int]$e.slots[$keyNext]) ([int]$d.slotTotals[$keyNext])
        minutesSinceLastUsed                = $mins
        timesReopenedSoonAfterToolClosedIt  = [int]$e.reopened
        timesUserRefusedToCloseIt           = [int]$e.rejected
        timesUserAgreedToCloseIt            = [int]$e.accepted
    }
}

# Each mistake makes the tool more careful with that app; each "yes" a bit bolder.
function Get-AutoCloseAt($d, $app) {
    $e = $d.apps[$app.id]
    $base = [double]$Config.autoCloseAt
    $t = $base + 0.05 * ([int]$e.reopened + [int]$e.rejected) - 0.02 * [int]$e.accepted
    return [math]::Min(0.99, [math]::Max($base - 0.10, $t))
}

# ================================================================ actions

function Stop-App($app, [switch]$Quiet) {
    if ($app.process -and ($Config.neverTouch -contains $app.process)) {
        Write-Host "  skip $($app.id): protected" -ForegroundColor Yellow; return $false
    }
    if (-not (Test-AppRunning $app)) { if (-not $Quiet) { Write-Host "  $($app.id): not running" }; return $false }

    $before = Get-AppMemoryMB $app
    if ($app.kind -eq 'service') {
        if (-not (Test-IsAdmin)) {
            Write-Host "  $($app.id): stopping a service needs an Administrator PowerShell - skipped" -ForegroundColor Yellow
            return $false
        }
        Stop-Service -Name $app.service -Force
    }
    else {
        if ($app.stopCommand) {
            $cmd = @($app.stopCommand | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
            Start-Process -FilePath $cmd[0] -ArgumentList ($cmd | Select-Object -Skip 1) | Out-Null
        } else {
            # Polite close first (like clicking X) so apps can save.
            Get-Process -Name $app.process -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
        }
        Start-Sleep -Seconds 4
        if ((Test-AppRunning $app) -and $app.forceOk) {
            Get-Process -Name $app.process -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    if (Test-AppRunning $app) {
        Write-Host "  $($app.id): did not close (it may be minimised to the tray). Close it yourself if you want." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  closed $($app.label)  (~$before MB freed)" -ForegroundColor Green
    Write-Log "CLOSED $($app.id) ~$before MB"
    $d = Load-Data
    $d.closed[$app.id] = (Get-Date).ToString('o')
    if ($d.closedByTool -notcontains $app.id) { $d.closedByTool += $app.id }
    Save-Data $d
    return $true
}

function Start-App($app) {
    # Forget the pending close first, so this start isn't counted as a "reopen mistake".
    $d = Load-Data
    $d.closed.Remove($app.id)
    $d.closedByTool = @($d.closedByTool | Where-Object { $_ -ne $app.id })
    Save-Data $d

    if (Test-AppRunning $app) { Write-Host "  $($app.id): already running"; return }
    if ($app.kind -eq 'service') {
        if (-not (Test-IsAdmin)) { Write-Host "  $($app.id): starting a service needs an Administrator PowerShell - skipped" -ForegroundColor Yellow; return }
        Start-Service -Name $app.service
    } elseif ($app.start) {
        $target = [Environment]::ExpandEnvironmentVariables($app.start)
        if ($target -like 'shell:*') { Start-Process explorer.exe -ArgumentList $target }
        else { Start-Process -FilePath $target }
    } else {
        Write-Host "  $($app.id): no start command (it starts on its own when needed)"; return
    }
    Write-Host "  started $($app.label)" -ForegroundColor Green
    Write-Log "STARTED $($app.id)"
}

# ================================================================ Jev

function Get-ApiKey {
    $k = $env:OPENROUTER_API_KEY
    if (-not $k) { $k = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User') }
    if (-not $k) { throw "No API key. Run:  .\ram setkey" }
    return $k
}

function Build-JevState($d, $candidates) {
    $now = Get-Date
    $perSample = [double]$Config.sampleEverySeconds / 60

    $usage = @{}
    foreach ($r in $d.recent) { $usage[$r.app] = 1 + [int]$usage[$r.app] }
    $recentUse = @($usage.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 |
        ForEach-Object { [ordered]@{ app = $_.Key; minutesInLastHour = [math]::Round($_.Value * $perSample, 1) } })

    $totalSamples = 0; foreach ($v in $d.slotTotals.Values) { $totalSamples += [int]$v }
    $trackedHours = [math]::Round($totalSamples * [double]$Config.sampleEverySeconds / 3600, 1)

    $apps = foreach ($a in $candidates) {
        [ordered]@{
            id              = $a.id
            name            = $a.label
            userPriority    = $a.priority
            memoryMB        = Get-AppMemoryMB $a
            learnedUsage    = Get-LearnedProfile $d $a
        }
    }

    # Only plain structured facts go in - no window titles or page text.
    [ordered]@{
        localTime      = $now.ToString('HH:mm')
        dayOfWeek      = $now.DayOfWeek.ToString()
        ram            = Get-RamInfo
        appInFrontNow  = Get-ForegroundProcessName
        recentAppUsage = $recentUse
        learning       = [ordered]@{
            trackedDays  = $d.trackedDays.Count
            trackedHours = $trackedHours
            meaning      = "learnedUsage percentages come from watching this user. With few tracked hours they are weak evidence; null means no data yet. Reopened-soon and refused counts mean closing that app annoyed the user before."
        }
        backgroundApps = @($apps)
        priorityScale  = "always > sometimes > rarely (set by the user)"
    }
}

function Invoke-Jev($d) {
    $candidates = @($Config.apps | Where-Object { $_.enabled -ne $false -and (Test-AppRunning $_) })
    if ($candidates.Count -eq 0) { Write-Host "No managed apps are running - nothing to decide."; return @() }

    $questions = [ordered]@{}
    foreach ($a in $candidates) {
        $questions["app_$($a.id)"] = [ordered]@{
            type         = 'choice'
            instructions = "Should the background app with id '$($a.id)' be kept running or closed right now to save RAM? Weigh this user's learned usage pattern for it most (how often and when they use it, and whether closing it annoyed them before), then RAM pressure and memory freed."
            criteria     = [ordered]@{
                keep  = "The user is using it, usually uses it around this time or soon, reopened it after it was closed before, or closing it frees very little memory."
                close = "The user rarely uses it, especially at this time of day, has not needed it recently, and closing it frees meaningful memory."
            }
        }
    }

    $body = [ordered]@{
        model     = $Config.model
        state     = Build-JevState $d $candidates
        questions = $questions
    } | ConvertTo-Json -Depth 10

    $headers = @{ Authorization = "Bearer $(Get-ApiKey)" }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $Config.endpoint -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    } catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "Jev request failed: $detail"
    }

    $cost = if ($resp.usage -and $null -ne $resp.usage.cost) { $resp.usage.cost } else { '?' }
    Write-Log "JEV model=$($resp.model) id=$($resp.id) cost=$cost"

    $results = foreach ($a in $candidates) {
        $ans = $resp.answers."app_$($a.id)"
        if (-not $ans -or $ans.type -ne 'choice') {
            [pscustomobject]@{ App = $a; PClose = 0.0; Needs = (Get-AutoCloseAt $d $a) }
            continue
        }
        $pClose = 0.0
        if ($ans.probabilities -and $null -ne $ans.probabilities.close) { $pClose = [double]$ans.probabilities.close }
        elseif ($ans.choice -eq 'close' -and $ans.confidence) { $pClose = [double]$ans.confidence }
        [pscustomobject]@{ App = $a; PClose = $pClose; Needs = (Get-AutoCloseAt $d $a) }
    }
    Write-Host ("Jev model {0}, cost {1}" -f $resp.model, $cost) -ForegroundColor DarkGray
    return @($results)
}

function Get-Verdict($r) {
    if ($r.PClose -ge $r.Needs) { 'close' }
    elseif ($r.PClose -ge [double]$Config.askAt) { 'maybe' }
    else { 'keep' }
}

function Show-Decisions($results) {
    Write-Host ""
    Write-Host ("{0,-14} {1,7} {2,9} {3,7}  {4}" -f 'APP', 'RAM MB', 'P(close)', 'NEEDS', 'VERDICT')
    foreach ($r in ($results | Sort-Object PClose -Descending)) {
        $v = Get-Verdict $r
        $label = switch ($v) { 'close' { 'close' } 'maybe' { 'maybe (will ask)' } default { 'keep' } }
        $color = switch ($v) { 'close' { 'Green' } 'maybe' { 'Yellow' } default { 'Gray' } }
        Write-Host ("{0,-14} {1,7} {2,9:P0} {3,7:P0}  {4}" -f $r.App.id, (Get-AppMemoryMB $r.App), $r.PClose, $r.Needs, $label) -ForegroundColor $color
    }
    Write-Host "(NEEDS = how sure Jev must be to auto-close; it rises for apps you reopened or refused to close.)" -ForegroundColor DarkGray
    Write-Host ""
}

# Applies verdicts. Interactive: ask about "maybe" and learn from your answer.
function Invoke-Decisions($results, [bool]$Interactive) {
    $fg = Get-ForegroundProcessName
    foreach ($r in ($results | Sort-Object PClose -Descending)) {
        $a = $r.App
        if ($fg -and $a.process -eq $fg) { continue }   # never close what you're looking at
        $v = Get-Verdict $r
        if ($v -eq 'close') {
            [void](Stop-App $a)
        } elseif ($v -eq 'maybe') {
            if ($Interactive) {
                $ans = Read-Host ("Close {0} ({1} MB)? Jev is {2:P0} sure. [y/N]" -f $a.label, (Get-AppMemoryMB $a), $r.PClose)
                $d = Load-Data
                if ($ans -match '^(y|yes)$') { $d.apps[$a.id].accepted++; Save-Data $d; [void](Stop-App $a) }
                else { $d.apps[$a.id].rejected++; Save-Data $d; Write-Log "LEARN user refused to close $($a.id)" }
            } else {
                Write-Log ("SUGGEST close {0} p={1:N2} (needs {2:N2} to auto-close)" -f $a.id, $r.PClose, $r.Needs)
            }
        }
    }
}

# ================================================================ commands

# The UI (ram-ui.ps1) loads this file only for its functions.
if ($Command -eq '__lib') { return }

switch ($Command.ToLower()) {

    'setkey' {
        $sec = Read-Host "Paste your OpenRouter API key (input is hidden)" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $plain.Trim()) { throw "Empty key." }
        [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $plain.Trim(), 'User')
        $env:OPENROUTER_API_KEY = $plain.Trim()
        Write-Host "Saved to your Windows user environment (OPENROUTER_API_KEY)." -ForegroundColor Green
    }

    'status' {
        $ram = Get-RamInfo
        Write-Host ("RAM: {0}% used, {1} GB free of {2} GB" -f $ram.usedPercent, $ram.availableGB, $ram.totalGB)
        Write-Host ""
        foreach ($a in $Config.apps) {
            $run = Test-AppRunning $a
            $s = if ($run) { "running  {0,6} MB" -f (Get-AppMemoryMB $a) } else { "stopped" }
            Write-Host ("  {0,-14} {1,-10} {2}" -f $a.id, $a.priority, $s) -ForegroundColor $(if ($run) { 'White' } else { 'DarkGray' })
        }
    }

    'stats' {
        $d = Load-Data
        $total = 0; foreach ($v in $d.slotTotals.Values) { $total += [int]$v }
        Write-Host ("Learned from {0} day(s), {1:N1} hours of watching." -f $d.trackedDays.Count, ($total * [double]$Config.sampleEverySeconds / 3600))
        if ($total -eq 0) { Write-Host "Nothing learned yet - run '.\ram watch' (or '.\ram autostart on')." -ForegroundColor Yellow }
        Write-Host ""
        Write-Host ("{0,-14} {1,9} {2,10} {3,9} {4,9} {5,8} {6,7}" -f 'APP', 'DAYS USED', 'THIS HOUR', 'LAST USED', 'REOPENED', 'REFUSED', 'NEEDS')
        foreach ($a in $Config.apps) {
            $p = Get-LearnedProfile $d $a
            $fmt = { param($x, $suffix) if ($null -eq $x) { '-' } else { "$x$suffix" } }
            Write-Host ("{0,-14} {1,9} {2,10} {3,9} {4,9} {5,8} {6,7:P0}" -f $a.id,
                (& $fmt $p.percentOfTrackedDaysUsed '%'), (& $fmt $p.usedAtThisHourOnAnyDayPercent '%'),
                (& $fmt $p.minutesSinceLastUsed 'm'), $p.timesReopenedSoonAfterToolClosedIt,
                $p.timesUserRefusedToCloseIt, (Get-AutoCloseAt $d $a))
        }
    }

    'decide' {
        $d = Load-Data
        $results = Invoke-Jev $d
        if ($results) { Show-Decisions $results; Write-Host "Dry run - nothing was closed. Use 'run' to act." -ForegroundColor DarkGray }
    }

    'run' {
        $d = Load-Data
        $results = Invoke-Jev $d
        if ($results) { Show-Decisions $results; Invoke-Decisions $results $true }
        $ram = Get-RamInfo; Write-Host ("RAM now: {0}% used" -f $ram.usedPercent)
    }

    'watch' {
        $mode = if ($Config.autoApply) { 'AUTO (closes apps when Jev is sure enough)' } else { 'LEARN + SUGGEST (logs to data\decisions.log, closes nothing)' }
        Write-Host "Watching. Mode: $mode. Ctrl+C to stop." -ForegroundColor Cyan
        Write-Log "WATCH started ($mode)"
        $lastDecide = [datetime]::MinValue
        $cpuPrev = @{}
        while ($true) {
            try {
                # Re-read settings each round so changes made in the UI apply without a restart.
                $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
                $d = Load-Data
                Add-UsageSample $d $cpuPrev
                Save-Data $d

                $ram = Get-RamInfo
                $due = ((Get-Date) - $lastDecide).TotalMinutes -ge $Config.decideEveryMinutes
                if ($due -and $ram.usedPercent -ge $Config.onlyWhenRamAbove) {
                    $lastDecide = Get-Date
                    $results = Invoke-Jev $d
                    if ($results) {
                        Show-Decisions $results
                        if ($Config.autoApply) { Invoke-Decisions $results $false }
                        else { foreach ($r in $results) { if ((Get-Verdict $r) -ne 'keep') { Write-Log ("SUGGEST close {0} p={1:N2} (needs {2:N2})" -f $r.App.id, $r.PClose, $r.Needs) } } }
                    }
                }
            } catch { Write-Warning $_.Exception.Message; Write-Log "ERROR $($_.Exception.Message)" }
            Start-Sleep -Seconds $Config.sampleEverySeconds
        }
    }

    'autostart' {
        if ($Name -eq 'off') { Set-Autostart $false; Write-Host "Autostart off." -ForegroundColor Green; break }
        Set-Autostart $true
        Write-Host "Autostart on: 'watch' will run hidden every time you log in." -ForegroundColor Green
        Write-Host "To start it now without logging out:  Start-Process '$AutostartLink'"
    }

    'mode' {
        $m = $Config.modes.$Name
        if (-not $m) { throw "Unknown mode '$Name'. Options: $(($Config.modes.PSObject.Properties.Name) -join ', ')" }
        Write-Host "Switching to '$Name' mode" -ForegroundColor Cyan
        foreach ($id in $m.stop)  { [void](Stop-App (Get-App $id) -Quiet) }
        foreach ($id in $m.start) { Start-App (Get-App $id) }
        $ram = Get-RamInfo; Write-Host ("RAM now: {0}% used" -f $ram.usedPercent)
    }

    'restore' {
        $d = Load-Data
        if (-not $d.closedByTool) { Write-Host "Nothing to restore."; break }
        foreach ($id in @($d.closedByTool)) { Start-App (Get-App $id) }
    }

    default { Get-Help $PSCommandPath; Write-Host "Commands: setkey, status, stats, decide, run, watch, autostart on|off, mode <light|work|normal>, restore" }
}
