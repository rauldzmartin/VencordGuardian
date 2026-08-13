# VencordGuardian

> Tired of Vencord vanishing overnight because of Discord updates?

VencordKeeper is a simple PowerShell script that repairs/updates **Vencord** automatically and sends native Windows notifications with the result.

## What it does

- Runs the official Vencord installer (`VencordInstallerCli.exe -repair -branch auto`) to repair/update Vencord.
- Closes Discord before repairing and relaunches it afterwards (respecting minimize-to-tray settings).
- Sends a Windows toast notification with the official Vencord icon when done.
- Writes a log file per run to `logs/` and an entry to the Windows Event Log.
- Creates a daily scheduled task (`VencordGuardian-Daily` at 07:00) so it runs automatically.
- Downloads the installer automatically if it's not already on disk.

## Installation

1. Save `vencord-guardian.ps1` anywhere you like.
2. Run it once with PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File vencord-guardian.ps1
```

That's it. It will create the scheduled task, register notifications, and run a repair right away. From then on it runs daily on its own.

### Parameters

| Parameter    | Description                                                        |
|--------------|--------------------------------------------------------------------|
| `-Installer` | Path to the Vencord installer. If omitted, it's searched locally and downloaded if missing. |
| `-NoRegister`| Skip creating/updating the scheduled task.                         |
| `-NoNotify`  | Skip notification registration and sending.                        |

## Notes

- Requires Windows 10/11 and PowerShell 5.1+.
- Not affiliated with Vencord or Discord.
