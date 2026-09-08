# VencordGuardian

> Tired of Vencord vanishing overnight because of Discord updates?

VencordGuardian is a simple PowerShell script that repairs/updates **Vencord** automatically and sends native Windows notifications with the result.

## Install

Open PowerShell and run this single line:

```powershell
iwr https://raw.githubusercontent.com/rauldzmartin/VencordGuardian/main/install.ps1 -OutFile "$env:TEMP\install.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
```

That's it. It downloads the script, installs it, and runs a repair right away. From then on it runs daily on its own. Re-running the same line updates VencordGuardian to the latest version.

> Note: the command downloads and runs a script from this repository. If you prefer, review [install.ps1](https://github.com/rauldzmartin/VencordGuardian/blob/main/install.ps1) first, or use the Manual install section below.

## What it does

- **Smart verification**: verifies whether Vencord is actually missing or unpatched before taking any action. If already patched and working, it exits silently in milliseconds without closing Discord or sending notifications.
- Runs the official Vencord installer (`VencordInstallerCli.exe -repair -branch auto`) only when a repair is actually required (or when `-Force` is specified).
- Closes Discord before repairing and relaunches it afterwards (respecting minimize-to-tray settings).
- Sends a Windows toast notification with the official Vencord icon only when a repair occurs.
- Writes a log file per run to `logs/` and an entry to the Windows Event Log.
- Creates a daily scheduled task (`[Custom] VencordGuardian-Daily`) configured to run automatically upon wake from sleep, session unlock, logon, or at 07:00.
- Checks for active internet connectivity on wake/unlock (waiting up to 15s) and defers execution safely if offline.
- Downloads the installer automatically if it's not already on disk.

## Manual install

1. Save `VencordGuardian.ps1` anywhere you like.
2. Run it once with PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File VencordGuardian.ps1
```

That's it. It will create the scheduled task, register notifications, and run a repair right away. From then on it runs daily on its own.

### Parameters

| Parameter    | Description                                                        |
|--------------|--------------------------------------------------------------------|
| `-Installer` | Path to the Vencord installer. If omitted, it's searched locally and downloaded if missing. |
| `-NoRegister`| Skip creating/updating the scheduled task.                         |
| `-NoNotify`  | Skip notification registration and sending.                        |
| `-Force`     | Force repair even if Vencord is already patched.                   |

## Uninstall

To stop VencordGuardian from running daily, remove the scheduled task:

```powershell
Unregister-ScheduledTask -TaskName '[Custom] VencordGuardian-Daily' -Confirm:$false
```

To edit the task instead (e.g. change the run time), open `taskschd.msc` and locate `[Custom] VencordGuardian-Daily`, or from PowerShell:

```powershell
$trigger = New-ScheduledTaskTrigger -Daily -At 08:00
Set-ScheduledTask -TaskName '[Custom] VencordGuardian-Daily' -Trigger $trigger
```

Optionally remove the rest of its traces:

- Notification shortcut: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\VencordGuardian.lnk`
- Cached state and icon: `%LOCALAPPDATA%\VencordGuardian\` (contains `vencord.ico` and `last_fail_date.txt` if any)
- Run logs: the `logs/` folder next to the script

## Notes

- Requires Windows 10/11 and PowerShell 5.1+.
- Not affiliated with Vencord or Discord.
