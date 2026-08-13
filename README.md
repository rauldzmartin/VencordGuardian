# VencordGuardian

> Tired of Vencord vanishing overnight because of Discord updates?

VencordGuardian is a simple PowerShell script that repairs/updates **Vencord** automatically and sends native Windows notifications with the result.

## Install

Open PowerShell and run this single line:

```powershell
irm https://raw.githubusercontent.com/rauldzmartin/VencordGuardian/main/install.ps1 | iex
```

That's it. It downloads the script, installs it, and runs a repair right away. From then on it runs daily on its own. Re-running the same line updates VencordGuardian to the latest version.

> Note: the command downloads and runs a script from this repository. If you prefer, review [install.ps1](https://github.com/rauldzmartin/VencordGuardian/blob/main/install.ps1) first, or use the Manual install section below.

## What it does

- Runs the official Vencord installer (`VencordInstallerCli.exe -repair -branch auto`) to repair/update Vencord.
- Closes Discord before repairing and relaunches it afterwards (respecting minimize-to-tray settings).
- Sends a Windows toast notification with the official Vencord icon when done.
- Writes a log file per run to `logs/` and an entry to the Windows Event Log.
- Creates a daily scheduled task (`VencordGuardian-Daily` at 07:00) so it runs automatically.
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

## Uninstall

To stop VencordGuardian from running daily, remove the scheduled task:

```powershell
Unregister-ScheduledTask -TaskName 'VencordGuardian-Daily' -Confirm:$false
```

To edit the task instead (e.g. change the run time), open `taskschd.msc` and locate `VencordGuardian-Daily`, or from PowerShell:

```powershell
$trigger = New-ScheduledTaskTrigger -Daily -At 08:00
Set-ScheduledTask -TaskName 'VencordGuardian-Daily' -Trigger $trigger
```

Optionally remove the rest of its traces:

- Notification shortcut: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\VencordGuardian.lnk`
- Cached icon: `%LOCALAPPDATA%\VencordGuardian\`
- Run logs: the `logs/` folder next to the script

## Notes

- Requires Windows 10/11 and PowerShell 5.1+.
- Not affiliated with Vencord or Discord.
