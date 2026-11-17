# RAM Manager - simple window. Start it with ram-ui.cmd (double-click).
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ram-manager.ps1') '__lib'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:JevScores = @{}   # id -> P(close) from the last "Ask Jev"
$Priorities = @('always', 'sometimes', 'rarely')

# ---------------------------------------------------------------- window

$form = New-Object System.Windows.Forms.Form
$form.Text = 'RAM Manager'
$form.Size = New-Object System.Drawing.Size(1280, 620)
$form.MinimumSize = New-Object System.Drawing.Size(900, 420)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.AutoScaleMode = 'Dpi'

# --- top: RAM bar
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 46; $top.Padding = '10,10,10,4'
$ramLabel = New-Object System.Windows.Forms.Label
$ramLabel.AutoSize = $true; $ramLabel.Location = '10,14'
$ramLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$ramBar = New-Object System.Windows.Forms.ProgressBar
$ramBar.Location = '330,14'; $ramBar.Size = '300,20'; $ramBar.Anchor = 'Top,Left'
$learnLabel = New-Object System.Windows.Forms.Label
$learnLabel.AutoSize = $true; $learnLabel.Location = '650,16'; $learnLabel.ForeColor = 'DimGray'
$top.Controls.AddRange(@($ramLabel, $ramBar, $learnLabel))

# --- grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = 'White'; $grid.BorderStyle = 'None'
$grid.EditMode = 'EditOnEnter'

function Add-Col($type, $name, $header, $weight, [bool]$ro = $true) {
    $c = New-Object "System.Windows.Forms.DataGridView$type"
    $c.Name = $name; $c.HeaderText = $header; $c.FillWeight = $weight; $c.ReadOnly = $ro
    [void]$grid.Columns.Add($c); return $c
}
[void](Add-Col 'CheckBoxColumn' 'On' 'Manage' 45 $false)
[void](Add-Col 'TextBoxColumn' 'App' 'App' 190)
[void](Add-Col 'TextBoxColumn' 'Type' 'Type' 55)
$prioCol = Add-Col 'ComboBoxColumn' 'Priority' 'How often I need it' 110 $false
$prioCol.Items.AddRange($Priorities); $prioCol.FlatStyle = 'Flat'
[void](Add-Col 'CheckBoxColumn' 'Force' 'Force close' 50 $false)
[void](Add-Col 'TextBoxColumn' 'Status' 'Status' 65)
[void](Add-Col 'TextBoxColumn' 'Ram' 'RAM MB' 55)
[void](Add-Col 'TextBoxColumn' 'Login' 'Starts at login' 60)
[void](Add-Col 'TextBoxColumn' 'Days' 'Days used' 65)
[void](Add-Col 'TextBoxColumn' 'Hour' 'Used at this hour' 80)
[void](Add-Col 'TextBoxColumn' 'Last' 'Last used' 70)
[void](Add-Col 'TextBoxColumn' 'Mistakes' 'Reopened / refused' 85)
[void](Add-Col 'TextBoxColumn' 'Needs' 'Close at' 55)
[void](Add-Col 'TextBoxColumn' 'Jev' 'Jev says' 110)
$grid.Columns['On'].ToolTipText = 'Untick = the tool and Jev leave this app alone'
$grid.Columns['Priority'].ToolTipText = 'Tell it how important this app is to you. Jev weighs this with what it learned.'
$grid.Columns['Mistakes'].ToolTipText = 'Times you reopened it soon after the tool closed it / times you said No'
$grid.Columns['Needs'].ToolTipText = 'How sure Jev must be before it auto-closes this app (rises after mistakes)'
$grid.Columns['Force'].ToolTipText = 'Allow killing it if it ignores a normal close (needed for tray apps with no window). Unsaved work in it could be lost.'
$grid.Columns['Login'].ToolTipText = 'Starts automatically when you log in to Windows'

# --- bottom: buttons
$bottom = New-Object System.Windows.Forms.FlowLayoutPanel
$bottom.Dock = 'Bottom'; $bottom.Height = 92; $bottom.Padding = '8,6,8,4'; $bottom.WrapContents = $true

function New-Btn($text, $width = 120) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Width = $width; $b.Height = 30; $b.Margin = '3,3,3,3'
    [void]$bottom.Controls.Add($b); return $b
}
function New-Sep { $s = New-Object System.Windows.Forms.Label; $s.Width = 14; [void]$bottom.Controls.Add($s) }

$btnRefresh = New-Btn 'Refresh' 85
$btnAsk     = New-Btn 'Ask Jev (dry run)' 140
$btnClose   = New-Btn 'Close selected' 115
$btnStart   = New-Btn 'Start selected' 115
$btnCheck   = New-Btn 'Check safety' 105
New-Sep
$btnAdd     = New-Btn 'Find apps...' 100
$btnRemove  = New-Btn 'Remove app' 100
$btnReset   = New-Btn 'Reset learning' 115
$bottom.SetFlowBreak($btnReset, $true)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Auto-close when Jev is sure'; $chkAuto.AutoSize = $true; $chkAuto.Margin = '6,8,10,3'
$chkLogin = New-Object System.Windows.Forms.CheckBox
$chkLogin.Text = 'Learn in background (start at login)'; $chkLogin.AutoSize = $true; $chkLogin.Margin = '6,8,16,3'
[void]$bottom.Controls.AddRange(@($chkAuto, $chkLogin))
$btnLight  = New-Btn 'Light mode' 95
$btnWork   = New-Btn 'Work mode' 95
$btnNormal = New-Btn 'Normal mode' 100
$btnRestore = New-Btn 'Restore closed' 115

$status = New-Object System.Windows.Forms.StatusStrip
$statusText = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusText.Spring = $true; $statusText.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusText)

$form.Controls.Add($grid); $form.Controls.Add($top); $form.Controls.Add($bottom); $form.Controls.Add($status)

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnAsk, 'Asks Jev what it would close right now. Closes nothing.')
$tips.SetToolTip($chkAuto, 'Off = the background learner only writes suggestions to data\decisions.log')
$tips.SetToolTip($chkLogin, 'Runs the learner hidden whenever you log in, so it learns your habits')
$tips.SetToolTip($btnReset, 'Forget what was learned about the selected apps')
$tips.SetToolTip($btnAdd, 'Scan for background apps and services using RAM that are not in the list yet')

# ---------------------------------------------------------------- logic

function Set-Status($msg) { $statusText.Text = $msg; $form.Refresh() }

function Invoke-Busy([string]$msg, [scriptblock]$work) {
    $form.Cursor = 'WaitCursor'; Set-Status $msg
    try { & $work }
    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RAM Manager', 'OK', 'Warning'); Set-Status "Error: $($_.Exception.Message)" }
    finally { $form.Cursor = 'Default' }
}

function Get-SelectedApps {
    @($grid.SelectedRows | ForEach-Object { Get-App $_.Tag })
}

# The background learner can add apps to config.json too, so always start from the file on disk.
function Sync-Config { $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json }

function Set-AppProp($app, $prop, $value) {
    $app | Add-Member -NotePropertyName $prop -NotePropertyValue $value -Force
}

$script:Loading = $false
function Update-View {
    $script:Loading = $true
    try {
        Sync-Config
        $ram = Get-RamInfo
        $ramLabel.Text = "RAM: $($ram.usedPercent)% used  ($($ram.availableGB) GB free of $($ram.totalGB) GB)"
        $ramBar.Value = [math]::Min(100, [math]::Max(0, [int]$ram.usedPercent))

        $d = Load-Data
        $total = 0; foreach ($v in $d.slotTotals.Values) { $total += [int]$v }
        $hrs = $total * [double]$Config.sampleEverySeconds / 3600
        $learnLabel.Text = "Learned from {0} day(s), {1:N1} h of watching" -f $d.trackedDays.Count, $hrs

        $chkAuto.Checked = [bool]$Config.autoApply
        $chkLogin.Checked = Test-Autostart

        $selected = @($grid.SelectedRows | ForEach-Object { $_.Tag })
        $startup = Get-StartupNames
        $grid.Rows.Clear()
        foreach ($a in $Config.apps) {
            $p = Get-LearnedProfile $d $a
            $run = Test-AppRunning $a
            $fmt = { param($x, $s) if ($null -eq $x) { '-' } else { "$x$s" } }
            $last = if ($null -eq $p.minutesSinceLastUsed) { '-' }
                    elseif ($p.minutesSinceLastUsed -lt 60) { "$($p.minutesSinceLastUsed) min" }
                    elseif ($p.minutesSinceLastUsed -lt 2880) { "{0:N0} h" -f ($p.minutesSinceLastUsed / 60) }
                    else { "{0:N0} d" -f ($p.minutesSinceLastUsed / 1440) }
            $jev = '-'
            if ($script:JevScores.ContainsKey($a.id)) {
                $pc = $script:JevScores[$a.id]; $need = Get-AutoCloseAt $d $a
                $word = if ($pc -ge $need) { 'close' } elseif ($pc -ge [double]$Config.askAt) { 'maybe' } else { 'keep' }
                $jev = "{0} ({1:P0})" -f $word, $pc
            }
            $prio = if ($Priorities -contains $a.priority) { $a.priority } else { 'sometimes' }
            $login = [bool]($a.startsAtLogin -or $startup[([string]$a.process).ToLower()])
            $i = $grid.Rows.Add(
                ($a.enabled -ne $false), $a.label,
                $(if ($a.kind -eq 'service') { 'service' } else { 'app' }),
                $prio, [bool]$a.forceOk,
                $(if ($run) { 'running' } else { 'stopped' }),
                $(if ($run) { Get-AppMemoryMB $a } else { '' }),
                $(if ($login) { 'yes' } else { '' }),
                (& $fmt $p.percentOfTrackedDaysUsed '%'), (& $fmt $p.usedAtThisHourOnAnyDayPercent '%'),
                $last, ("{0} / {1}" -f $p.timesReopenedSoonAfterToolClosedIt, $p.timesUserRefusedToCloseIt),
                ("{0:P0}" -f (Get-AutoCloseAt $d $a)), $jev)
            $row = $grid.Rows[$i]
            $row.Tag = $a.id
            if (-not $run) { $row.DefaultCellStyle.ForeColor = 'Gray' }
            if ($a.enabled -eq $false) { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245) }
            if ($a.note) {
                $row.Cells['App'].ToolTipText = [string]$a.note
                $row.Cells['App'].Value = "(!) $($a.label)"
                $row.Cells['App'].Style.ForeColor = 'DarkGoldenrod'
            }
            if ($a.kind -eq 'service') { $row.Cells['Force'].ReadOnly = $true }
            if ($jev -like 'close*') { $row.Cells['Jev'].Style.ForeColor = 'DarkGreen' }
            elseif ($jev -like 'maybe*') { $row.Cells['Jev'].Style.ForeColor = 'DarkOrange' }
            $row.Selected = ($selected -contains $a.id)
        }
    } finally { $script:Loading = $false }
}

# Checkbox / dropdown changes save straight away.
$grid.add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
$grid.add_CellValueChanged({
    param($s, $e)
    if ($script:Loading -or $e.RowIndex -lt 0) { return }
    Sync-Config
    $row = $grid.Rows[$e.RowIndex]; $app = Get-App $row.Tag
    $col = $grid.Columns[$e.ColumnIndex].Name
    if ($col -eq 'On') {
        Set-AppProp $app 'enabled' ([bool]$row.Cells['On'].Value); Save-Config
        Set-Status ("{0} is now {1}" -f $app.label, $(if ($app.enabled) { 'managed' } else { 'left alone' }))
    } elseif ($col -eq 'Force') {
        Set-AppProp $app 'forceOk' ([bool]$row.Cells['Force'].Value); Save-Config
        Set-Status ("{0}: force close {1}" -f $app.label, $(if ($app.forceOk) { 'allowed' } else { 'off (normal close only)' }))
    } elseif ($col -eq 'Priority') {
        Set-AppProp $app 'priority' ([string]$row.Cells['Priority'].Value); Save-Config
        Set-Status ("Saved: {0} -> {1}" -f $app.label, $app.priority)
    }
})
$grid.add_DataError({ param($s, $e) $e.ThrowException = $false })

$btnRefresh.add_Click({ Invoke-Busy 'Refreshing...' { Update-View; Set-Status 'Up to date.' } })

$btnAsk.add_Click({
    Invoke-Busy 'Asking Jev...' {
        $results = Invoke-Jev (Load-Data)
        $script:JevScores = @{}
        foreach ($r in $results) { $script:JevScores[$r.App.id] = $r.PClose }
        Update-View
        Set-Status ("Jev answered for {0} running app(s). Nothing was closed. See 'Jev says' column." -f @($results).Count)
    }
})

$btnClose.add_Click({
    $apps = Get-SelectedApps
    if (-not $apps) { Set-Status 'Select one or more rows first.'; return }
    Invoke-Busy 'Closing (checking dependencies first, then verifying nothing broke)...' {
        $msgs = @()
        foreach ($a in $apps) {
            if (-not (Test-AppRunning $a)) { continue }
            $override = $false
            $issues = @(Get-SafetyIssues $a)
            if ($issues) {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    "Closing $($a.label) may affect other things:`n`n - $($issues -join "`n - ")`n`nClose it anyway? (It will still be undone automatically if something stops working.)",
                    'Safety check', 'YesNo', 'Warning', 'Button2')
                if ($ans -ne 'Yes') { $msgs += "$($a.label): kept (safety check)"; continue }
                $override = $true
            }
            $ok = if ($override) { Stop-App $a -Quiet -IgnoreWarnings } else { Stop-App $a -Quiet }
            $msgs += $(if ($script:LastStopMessage) { $script:LastStopMessage } elseif ($ok) { "Closed $($a.label)" } else { "$($a.label): not closed" })
        }
        Update-View
        Set-Status ($(if ($msgs) { $msgs -join '   |   ' } else { 'Nothing was running.' }))
    }
})

$btnCheck.add_Click({
    $apps = Get-SelectedApps
    if (-not $apps) { $apps = @($Config.apps | Where-Object { Test-AppRunning $_ }) }
    $lines = @()
    Invoke-Busy 'Checking what depends on each app...' {
        foreach ($a in $apps) {
            if (-not (Test-AppRunning $a)) { $lines += "-  $($a.label): not running"; continue }
            $issues = @(Get-SafetyIssues $a)
            $lines += $(if ($issues) { "(!) $($a.label): $($issues -join '; ')" } else { "OK  $($a.label): nothing depends on it" })
        }
    }
    $lines += ''; $lines += 'Every close is also verified afterwards (services, open apps, internet). If anything stopped working, the app is reopened and never closed again automatically.'
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), 'Safety check')
})

$btnStart.add_Click({
    $apps = Get-SelectedApps
    if (-not $apps) { Set-Status 'Select one or more rows first.'; return }
    Invoke-Busy 'Starting...' { foreach ($a in $apps) { Start-App $a }; Start-Sleep -Seconds 2; Update-View; Set-Status 'Started selected apps (services need Administrator).' }
})

$btnReset.add_Click({
    $apps = Get-SelectedApps
    if (-not $apps) { Set-Status 'Select one or more rows first.'; return }
    $ok = [System.Windows.Forms.MessageBox]::Show("Forget everything learned about:`n`n$(($apps | ForEach-Object { $_.label }) -join "`n")", 'Reset learning', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    $d = Load-Data
    foreach ($a in $apps) { $d.apps.Remove($a.id); Initialize-AppEntry $d $a.id }
    Save-Data $d; Update-View; Set-Status 'Learning reset for selected apps.'
})

$btnRemove.add_Click({
    $apps = Get-SelectedApps
    if (-not $apps) { Set-Status 'Select one or more rows first.'; return }
    $ok = [System.Windows.Forms.MessageBox]::Show("Stop managing these apps? (They are not uninstalled.)`n`n$(($apps | ForEach-Object { $_.label }) -join "`n")", 'Remove app', 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    Sync-Config
    $ids = @($apps | ForEach-Object { $_.id })
    foreach ($a in $apps) { if ($a.process) { Add-IgnoredProcess $a.process } }   # so discovery won't add it back
    $Config.apps = @($Config.apps | Where-Object { $ids -notcontains $_.id })
    foreach ($m in $Config.modes.PSObject.Properties) {
        $m.Value.stop  = @($m.Value.stop  | Where-Object { $ids -notcontains $_ })
        $m.Value.start = @($m.Value.start | Where-Object { $ids -notcontains $_ })
    }
    Save-Config; Update-View; Set-Status "Removed: $($ids -join ', ')"
})

$btnAdd.add_Click({
    $script:Found = @()
    Invoke-Busy 'Scanning for background apps and services (takes a few seconds)...' {
        $script:Found = @(Find-BackgroundApps | Sort-Object mb -Descending)
    }
    $found = $script:Found
    if (-not $found) { Set-Status 'No new background apps found - everything worth managing is already listed.'; return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Found background apps'; $dlg.Size = '760,480'; $dlg.StartPosition = 'CenterParent'; $dlg.Font = $form.Font
    $hint = New-Object System.Windows.Forms.Label; $hint.Dock = 'Top'; $hint.Height = 44; $hint.Padding = '6,6,6,0'
    $hint.Text = "Ticked = add and manage. Unticked = ignore (won't be suggested again).`n(!) = hardware/security helper or started by Windows - unticked by default."
    $cl = New-Object System.Windows.Forms.CheckedListBox
    $cl.Dock = 'Fill'; $cl.CheckOnClick = $true; $cl.IntegralHeight = $false
    for ($i = 0; $i -lt $found.Count; $i++) {
        $a = $found[$i].app
        $flags = @()
        if ($a.kind -eq 'service') { $flags += 'service' }
        if ($a.startsAtLogin) { $flags += 'starts at login' }
        $text = "{0,5} MB   {1}{2}   [{3}]{4}" -f $found[$i].mb, $(if ($a.note -and -not $a.enabled) { '(!) ' } else { '' }), $a.label, $a.process, $(if ($flags) { '   - ' + ($flags -join ', ') } else { '' })
        [void]$cl.Items.Add($text, [bool]$a.enabled)
    }
    $pnl = New-Object System.Windows.Forms.FlowLayoutPanel; $pnl.Dock = 'Bottom'; $pnl.Height = 44; $pnl.FlowDirection = 'RightToLeft'
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.DialogResult = 'OK'; $ok.Width = 90; $ok.Height = 30
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'; $cancel.Width = 90; $cancel.Height = 30
    $pnl.Controls.AddRange(@($cancel, $ok))
    $dlg.Controls.AddRange(@($cl, $hint, $pnl)); $dlg.AcceptButton = $ok
    if ($dlg.ShowDialog($form) -ne 'OK') { return }

    Sync-Config
    $toAdd = @()
    for ($i = 0; $i -lt $found.Count; $i++) {
        if ($cl.GetItemChecked($i)) { $found[$i].app.enabled = $true; $toAdd += $found[$i] }
        else { Add-IgnoredProcess $found[$i].app.process }
    }
    $added = @(Add-DiscoveredApps $toAdd)
    Save-Config; Update-View
    Set-Status ("Added {0} app(s), ignored {1}. Tick 'Force close' for tray apps that have no window." -f $added.Count, ($found.Count - $added.Count))
})

$chkAuto.add_Click({
    Sync-Config
    Set-AppProp $Config 'autoApply' $chkAuto.Checked; Save-Config
    Set-Status $(if ($chkAuto.Checked) { 'Auto-close ON: the background learner will close apps when Jev is sure enough.' } else { 'Auto-close OFF: suggestions only (data\decisions.log).' })
})

$chkLogin.add_Click({
    Set-Autostart $chkLogin.Checked
    if ($chkLogin.Checked) {
        $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*ram-manager.ps1*watch*' }
        if (-not $running) { Start-Process $AutostartLink }
        Set-Status 'Background learner is on and will start at every login.'
    } else {
        Set-Status 'It will no longer start at login. (A learner already running keeps going until you sign out.)'
    }
})

$btnLight.Tag = 'light'; $btnWork.Tag = 'work'; $btnNormal.Tag = 'normal'
foreach ($b in @($btnLight, $btnWork, $btnNormal)) {
    $b.add_Click({
        $mode = [string]$this.Tag
        Invoke-Busy "Switching to $mode mode..." {
            $m = $Config.modes.$mode
            foreach ($id in @($m.stop))  { try { [void](Stop-App (Get-App $id) -Quiet) } catch {} }
            foreach ($id in @($m.start)) { try { Start-App (Get-App $id) } catch {} }
            Update-View; Set-Status "$mode mode applied."
        }
    })
}

$btnRestore.add_Click({
    Invoke-Busy 'Restoring...' {
        $d = Load-Data
        $ids = @($d.closedByTool)
        foreach ($id in $ids) { try { Start-App (Get-App $id) } catch {} }
        Start-Sleep -Seconds 2; Update-View
        Set-Status $(if ($ids) { "Reopened: $($ids -join ', ')" } else { 'Nothing to restore.' })
    }
})

# Keep the RAM numbers fresh.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.add_Tick({ if (-not $grid.IsCurrentCellInEditMode) { Update-View } })

if ($SelfTest) {
    # Build the table without showing the window, print it, and exit.
    $form.CreateControl(); $grid.CreateControl()
    Update-View
    "$($ramLabel.Text) | $($learnLabel.Text) | auto=$($chkAuto.Checked) login=$($chkLogin.Checked)"
    foreach ($r in $grid.Rows) { ($r.Cells | ForEach-Object { "$($_.Value)" }) -join ' | ' }
    return
}

$form.add_Shown({ Update-View; Set-Status 'Tip: change "How often I need it" or untick "Manage" - it saves instantly.'; $timer.Start() })
try { [void]$form.ShowDialog() }
catch {
    Add-Content (Join-Path $DataDir 'ui-error.log') "$(Get-Date -Format s) $($_.Exception.Message)"
    [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'RAM Manager error')
}
$timer.Stop()
