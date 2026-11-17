# RAM Manager

Free up RAM on Windows by closing background apps you aren't using, and keep the ones you need.

A lot of RAM goes to apps that start with Windows and stay in the background: sync tools, phone companions, voice assistants and local database servers. RAM Manager watches which apps you actually use and when, then closes the idle ones. It gets better the longer it runs.

## What it does for you

- **Frees memory automatically.** It closes background apps you haven't touched, often freeing 1 GB or more on a typical laptop.
- **Finds background apps by itself.** It scans for every third-party app and service using RAM, including tray apps, helpers that start with Windows, and vendor services, and adds them for you. Windows itself, helpers that belong to another app, and anything you launched from a command line are skipped. Hardware and security helpers, and components Windows restarts on its own, are listed but stay off until you choose to manage them. It rescans every hour.
- **Learns your habits.** It records which apps you use, on which days and at which hours. An app you use every evening is kept in the evening and closed in the morning.
- **Learns from mistakes.** If you reopen an app soon after it was closed, or you answer "No" when it asks, it becomes more careful with that app.
- **Safe by default.** It never closes the window you're working in, or apps on the protected list (browsers, editors, Explorer, terminals). It closes apps politely first so they can save. Until you turn on auto-close, it only suggests.
- **Checks before closing, verifies after.** Before closing anything, it checks whether other services depend on it, whether Windows allows it to be stopped, and whether closing it would also take down programs from other publishers. After closing, it checks that automatic services, your open apps and your internet connection still work. If anything stopped, it reopens the app straight away and never auto-closes it again.
- **Undo in one click.** **Restore closed** reopens everything it closed.
- **Simple window.** See RAM use and what it has learned, set how important each app is, and add or remove apps. No config editing needed.
- **Very cheap.** Decisions are made by [TypeSafe Jev](https://openrouter.ai/docs/guides/community/jev), a decision model, through OpenRouter. Each check costs about $0.0001, so a full day of checks costs less than a cent.

## Requirements

- Windows 10 or 11 (uses the built-in PowerShell 5.1; nothing to install)
- An [OpenRouter](https://openrouter.ai) API key

## Setup

1. Download or clone this folder.
2. Save your API key. In PowerShell, inside the folder, run:
   ```
   .\ram setkey
   ```
   Paste the key when asked. The input is hidden, and the key is stored in your Windows user environment, not in any file.
3. Double-click **`ram-ui.cmd`** to open the window.
4. Tick **Learn in background**. It starts learning now and every time you log in.
5. After about a week, when its suggestions look right, tick **Auto-close when Jev is sure**.

## The window

| Column | Meaning |
|---|---|
| **Manage** | Untick to make the tool leave this app alone |
| **Type** | `app` or `service` (services need Administrator) |
| **How often I need it** | `always`, `sometimes` or `rarely`. Your hint, combined with what it learned |
| **Force close** | Lets it end an app that ignores a normal close. Tray apps with no window need this |
| **Starts at login** | The app launches automatically with Windows |
| **(!)** before a name | Hardware or security helper, or started by Windows. Hover for details |
| **Days used / Used at this hour / Last used** | What it has learned from watching |
| **Reopened / refused** | Times it closed the app too early, or you said No |
| **Close at** | How sure the AI must be before closing this app. It goes up after mistakes and down when you agree |
| **Jev says** | The latest decision after you click **Ask Jev (dry run)** |

Buttons: **Ask Jev (dry run)** (closes nothing), **Close / Start selected**, **Check safety** (what depends on the selected apps), **Find apps...** (scan for new background apps and choose which to manage; unticked ones are never suggested again), **Remove app**, **Reset learning**, **Light / Work / Normal mode** (fixed presets, no AI) and **Restore closed**.

## Command line

Run from the folder in PowerShell:

```
.\ram status              RAM use and managed apps
.\ram stats               what it has learned
.\ram discover            find background apps and services and add them
.\ram check [app-id]      show what depends on each app before you close it
.\ram decide              ask the AI what it would close (changes nothing)
.\ram run                 ask, then close; asks you when unsure
.\ram watch               learn in this window and check every 10 minutes
.\ram autostart on|off    learn in the background at every login
.\ram mode light|work|normal
.\ram restore             reopen everything it closed
```

## Settings

On first run, `config.example.json` is copied to `config.json`, which is your own copy. The main settings are:

| Setting | Default | Meaning |
|---|---|---|
| `autoApply` | `false` | Close apps automatically, instead of only suggesting |
| `autoCloseAt` | `0.85` | Confidence needed to close without asking |
| `askAt` | `0.60` | Confidence at which it asks you first |
| `onlyWhenRamAbove` | `70` | Only checks when RAM use is above this percent |
| `decideEveryMinutes` | `10` | How often it checks |
| `neverTouch` | browsers, editors... | Process names it will never close |
| `minMBToConsider` | `25` | Apps using less RAM than this are not worth closing |
| `discoverEveryMinutes` | `60` | How often the background learner looks for new apps |
| `ignored` | `[]` | Apps you told it to ignore. Filled in by the window |

## Notes

- **Windows services** (like MySQL) need the window or terminal to be run **as Administrator** to stop or start them.
- **Privacy.** Only plain facts are sent to the AI: the time, RAM use, app names, memory use and usage percentages. No window titles, file names or page content. Your usage history stays in `data/` on your PC.
- The tool's own background learner uses about 60–80 MB of RAM.
