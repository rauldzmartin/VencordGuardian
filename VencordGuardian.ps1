<#
.SYNOPSIS
  Repairs/updates Vencord automatically and sends a Windows toast with the result.

.DESCRIPTION
  Verifies whether Vencord is missing or unpatched in installed Discord versions.
  If unpatched (or when -Force is specified), resolves the official Vencord installer
  (local or downloaded), closes Discord, runs "VencordInstallerCli.exe -repair -branch auto",
  and relaunches Discord.
  Registers a daily scheduled task ([Custom] VencordGuardian-Daily at 07:00 and upon unlock/logon/wake)
  and a Start Menu shortcut with an AUMID for native notifications.

.PARAMETER Installer
  Path to the Vencord installer. If omitted, searched locally and downloaded if missing.

.PARAMETER NoRegister
  Skip creating/updating the scheduled task.

.PARAMETER NoNotify
  Skip notification registration and sending.

.PARAMETER Force
  Force repair even if Vencord is already patched.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File VencordGuardian.ps1

.NOTES
  Name: VencordGuardian
  Author: rauldzmartin
  Repository: https://github.com/rauldzmartin/VencordGuardian
#>
param(
    [string]$Installer = '',
    [switch]$NoRegister,
    [switch]$NoNotify,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# -- Constants ----------------------------------------------------------
$script:AppName           = 'VencordGuardian'
$script:TaskName          = '[Custom] VencordGuardian-Daily'
$script:InstallerExe      = 'VencordInstallerCli.exe'
$script:InstallerUrl      = 'https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe'
$script:IconUrl           = 'https://raw.githubusercontent.com/Vencord/Installer/main/winres/icon.ico'
$script:VencordPatcherRel = 'Vencord\dist\patcher.js'
$script:DiscordBranches   = @('Discord', 'DiscordPTB', 'DiscordCanary', 'DiscordDevelopment')
$script:MaxAsarSize       = 50000          # bytes - a patched app.asar is <1KB
$script:ConnTimeout       = 15             # seconds
$script:LogPrefix         = '[vencord]'
$script:LogRetentionDays  = 30

# -- Security Protocol --------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# -- Native Interop -----------------------------------------------------
if (-not ('Win32' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@
}

if (-not ('AumidHelper' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AumidHelper {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetPropertyStoreFromParsingName(string pszPath, IntPtr pbc, uint flags, ref Guid riid, out IPropertyStore ppv);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant pvar);

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        int GetCount(out uint cProps);
        int GetAt(uint iProp, out PropertyKey pkey);
        int GetValue(ref PropertyKey key, out PropVariant pv);
        int SetValue(ref PropertyKey key, ref PropVariant pv);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropVariant {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr val;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey {
        public Guid fmtid;
        public uint pid;
    }

    private static readonly Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    private static readonly PropertyKey PKEY_AppUserModelID = new PropertyKey {
        fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
        pid = 5
    };

    public static bool SetAumid(string lnkPath, string aumid) {
        Guid iid = IID_IPropertyStore;
        PropertyKey key = PKEY_AppUserModelID;
        IPropertyStore store;
        int hr = SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2, ref iid, out store);
        if (hr != 0 || store == null) return false;
        PropVariant pv = new PropVariant { vt = 31, val = Marshal.StringToCoTaskMemUni(aumid) };
        hr = store.SetValue(ref key, ref pv);
        if (hr == 0) hr = store.Commit();
        PropVariantClear(ref pv);
        try { Marshal.ReleaseComObject(store); } catch { }
        return hr == 0;
    }
}
'@ -ErrorAction Stop
}

# -- Functions ----------------------------------------------------------
function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('None', 'Info', 'Warning', 'Error')]
        [string]$Icon = 'None'
    )
    if ($NoNotify) { return }

    $sent = $false
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        $escapedTitle = if ($Title) { $Title.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;') } else { '' }
        $escapedMsg = if ($Message) { $Message.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;') } else { '' }

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$escapedTitle</text>
      <text>$escapedMsg</text>
    </binding>
  </visual>
</toast>
"@
        $xml.LoadXml($toastXml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:AppName).Show($toast)
        $sent = $true
    }
    catch {
        Write-Host "$($script:LogPrefix) Toast notification failed: $($_.Exception.Message)"
    }

    if (-not $sent) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $trayIcon = switch ($Icon) {
                'Error'   { [System.Drawing.SystemIcons]::Error }
                'Warning' { [System.Drawing.SystemIcons]::Warning }
                'Info'    { [System.Drawing.SystemIcons]::Information }
                default   { [System.Drawing.SystemIcons]::Application }
            }
            $balloonIcon = [System.Windows.Forms.ToolTipIcon]::$Icon
            $n = New-Object System.Windows.Forms.NotifyIcon
            $n.Icon = $trayIcon
            $n.Visible = $true
            $n.ShowBalloonTip(8000, $Title, $Message, $balloonIcon)
            Start-Sleep -Seconds 7
            $n.Dispose()
        }
        catch {
            Write-Warning "$($script:LogPrefix) Balloon notification failed: $($_.Exception.Message)"
        }
    }
}

function Get-VencordIcon {
    $dir = Join-Path $env:LOCALAPPDATA $script:AppName
    $ico = Join-Path $dir 'vencord.ico'
    if (Test-Path -LiteralPath $ico -PathType Leaf) { return $ico }
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Host "$($script:LogPrefix) Downloading icon: $($script:IconUrl)"
        Invoke-WebRequest -Uri $script:IconUrl -OutFile $ico -UseBasicParsing
        if (Test-Path -LiteralPath $ico -PathType Leaf) { return $ico }
    }
    catch {
        Write-Warning "$($script:LogPrefix) Could not download icon, falling back to default: $($_.Exception.Message)"
    }
    return $null
}

function Register-Aumid {
    $aumid = $script:AppName
    if (Get-StartApps | Where-Object { $_.AppID -eq $aumid }) { return }

    try {
        $lnkName = $script:AppName
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $lnkPath = Join-Path $startMenu "$lnkName.lnk"

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        $icon = Get-VencordIcon
        if ($icon) { $shortcut.IconLocation = "$icon,0" }
        $shortcut.Save()

        if (-not [AumidHelper]::SetAumid($lnkPath, $aumid)) {
            throw 'Could not set AppUserModelID on shortcut'
        }
        Write-Host "$($script:LogPrefix) Notifications registered as '$lnkName'"
    }
    catch {
        Write-Warning "$($script:LogPrefix) Could not register AUMID, falling back to legacy balloon tip: $($_.Exception.Message)"
    }
}

function Write-AppEvent {
    param([string]$Message, [string]$Kind = 'Information')
    try {
        New-EventLog -LogName Application -Source $script:AppName -ErrorAction SilentlyContinue
        $entryType = if ($Kind -eq 'Error') { [System.Diagnostics.EventLogEntryType]::Error } else { [System.Diagnostics.EventLogEntryType]::Information }
        Write-EventLog -LogName Application -Source $script:AppName -EventId 100 -EntryType $entryType -Message $Message -ErrorAction SilentlyContinue
    }
    catch { }
}

function Register-GuardianTask {
    try {
        $taskName = $script:TaskName
        $taskPath = $PSCommandPath
        $userName = "$env:USERDOMAIN\$env:USERNAME"
        $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $expectedTriggerCount = 4  # Calendar + Logon + Unlock + Wake

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $needsUpdate = -not $task
        if ($task) {
            $currentArg = $task.Actions | Select-Object -ExpandProperty Arguments
            $needsUpdate = -not ($currentArg -and $currentArg -like "*$taskPath*")
            if ($task.Triggers.Count -lt $expectedTriggerCount) { $needsUpdate = $true }
        }

        if ($needsUpdate) {
            $startDate = (Get-Date).ToString('yyyy-MM-dd') + 'T07:00:00'
            $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Repairs/updates Vencord daily upon wake/unlock or at 07:00</Description>
    <URI>\$taskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$userId</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <Duration>PT10M</Duration>
      <WaitTimeout>PT1H</WaitTimeout>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startDate</StartBoundary>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger>
      <UserId>$userName</UserId>
      <Enabled>true</Enabled>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <UserId>$userName</UserId>
      <StateChange>SessionUnlock</StateChange>
    </SessionStateChangeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$taskPath`"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
            Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
            Write-Host "$($script:LogPrefix) Scheduled task $taskName created/updated"
        }
    }
    catch {
        Write-Warning "$($script:LogPrefix) Could not ensure scheduled task: $($_.Exception.Message)"
    }
}

function Get-VencordInstaller {
    if ($Installer) {
        if (Test-Path -LiteralPath $Installer -PathType Leaf) { return $Installer }
        throw "Installer not found: $Installer"
    }

    $candidates = @(
        (Join-Path $PSScriptRoot $script:InstallerExe),
        (Join-Path $env:USERPROFILE "Downloads\$($script:InstallerExe)"),
        (Join-Path $env:USERPROFILE "Desktop\$($script:InstallerExe)"),
        (Join-Path $env:TEMP $script:InstallerExe)
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

    if ($candidates) { return $candidates }

    $target = Join-Path $env:TEMP $script:InstallerExe
    Write-Host "$($script:LogPrefix) Downloading installer: $($script:InstallerUrl)"
    Invoke-WebRequest -Uri $script:InstallerUrl -OutFile $target -UseBasicParsing
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Could not download Vencord installer' }
    return $target
}

function Remove-IncompleteDiscordUpdates {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    Get-ChildItem -LiteralPath $Root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | ForEach-Object {
        $res = Join-Path $_.FullName 'resources'
        $hasAsar = (Test-Path -LiteralPath (Join-Path $res 'app.asar')) -or (Test-Path -LiteralPath (Join-Path $res '_app.asar'))
        if (-not $hasAsar) {
            Write-Host "$($script:LogPrefix) Removed incomplete Discord folder: $($_.Name)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
    }
}

function Remove-OldLogs {
    param(
        [string]$LogDir,
        [int]$RetentionDays = 30
    )
    Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Wait-InternetConnection {
    param([int]$TimeoutSeconds = $script:ConnTimeout)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $hosts = @(
        @{ Host = '1.1.1.1'; Port = 53 },
        @{ Host = '8.8.8.8'; Port = 53 },
        @{ Host = 'github.com'; Port = 443 }
    )

    do {
        foreach ($target in $hosts) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $client.BeginConnect($target.Host, $target.Port, $null, $null)
                $success = $asyncResult.AsyncWaitHandle.WaitOne(1000, $false)
                if ($success -and $client.Connected) {
                    $client.EndConnect($asyncResult)
                    $client.Close()
                    return $true
                }
                $client.Close()
            }
            catch { }
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Test-VencordPatch {
    <#
    .SYNOPSIS
      Checks if all detected Discord installations are properly patched with Vencord.
      Returns $true if intact, $false if repair/patching is needed.
    #>
    $patcherJs = Join-Path $env:APPDATA $script:VencordPatcherRel
    if (-not (Test-Path -LiteralPath $patcherJs -PathType Leaf)) {
        Write-Host "$($script:LogPrefix) Vencord runtime not found at $patcherJs"
        return $false
    }

    $candidateDirs = [System.Collections.Generic.List[string]]::new()

    $runningDiscord = Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.ProcessName -notlike '*SystemHelper*' } | Select-Object -First 1
    if ($runningDiscord -and $runningDiscord.Path) {
        $procRoot = Split-Path (Split-Path $runningDiscord.Path -Parent) -Parent
        if ($procRoot -and (Test-Path -LiteralPath $procRoot -PathType Container)) {
            $candidateDirs.Add($procRoot)
        }
    }

    foreach ($b in $script:DiscordBranches) {
        $dir = Join-Path $env:LOCALAPPDATA $b
        if ((Test-Path -LiteralPath $dir -PathType Container) -and -not $candidateDirs.Contains($dir)) {
            $candidateDirs.Add($dir)
        }
    }

    if ($candidateDirs.Count -eq 0) {
        Write-Host "$($script:LogPrefix) No Discord install directories found"
        return $false
    }

    $foundValidInstall = $false

    foreach ($dir in $candidateDirs) {
        Remove-IncompleteDiscordUpdates -Root $dir

        $appDirs = @(Get-ChildItem -LiteralPath $dir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Where-Object {
            $res = Join-Path $_.FullName 'resources'
            (Test-Path -LiteralPath (Join-Path $res 'app.asar')) -or (Test-Path -LiteralPath (Join-Path $res '_app.asar'))
        } | Sort-Object {
            try { [version]($_.Name -replace '^app-', '') } catch { $_.Name }
        })

        if ($appDirs.Count -eq 0) { continue }

        $foundValidInstall = $true
        $latestApp = $appDirs[-1]
        $resources = Join-Path $latestApp.FullName 'resources'

        $underscoreAsar = Join-Path $resources '_app.asar'
        $appAsar = Join-Path $resources 'app.asar'

        if (-not (Test-Path -LiteralPath $underscoreAsar -PathType Leaf)) {
            Write-Host "$($script:LogPrefix) Missing _app.asar in $($latestApp.FullName)"
            return $false
        }

        if (-not (Test-Path -LiteralPath $appAsar -PathType Leaf)) {
            Write-Host "$($script:LogPrefix) Missing app.asar in $($latestApp.FullName)"
            return $false
        }

        $item = Get-Item -LiteralPath $appAsar
        if ($item.Length -gt $script:MaxAsarSize) {
            Write-Host "$($script:LogPrefix) app.asar in $($latestApp.FullName) exceeds $($script:MaxAsarSize) bytes ($($item.Length) bytes), unpatched stock file suspected"
            return $false
        }

        $content = Get-Content -LiteralPath $appAsar -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch 'patcher\.js' -and $content -notmatch 'Vencord') {
            Write-Host "$($script:LogPrefix) app.asar in $($latestApp.FullName) does not contain Vencord loader"
            return $false
        }
    }

    if (-not $foundValidInstall) {
        Write-Host "$($script:LogPrefix) No valid Discord version found"
        return $false
    }

    return $true
}

function Restart-Discord {
    param(
        [string]$BranchRoot,
        [string]$ProcessName,
        [string]$ExeFallback,
        [string]$AppDataBranch
    )

    $updateExe = if ($BranchRoot) { Join-Path $BranchRoot 'Update.exe' } else { $null }
    if ($updateExe -and (Test-Path -LiteralPath $updateExe -PathType Leaf)) {
        $cmd = "`"$updateExe`" --processStart $ProcessName"
        ([wmiclass]'Win32_Process').Create($cmd) | Out-Null
    }
    elseif ($ExeFallback -and (Test-Path -LiteralPath $ExeFallback -PathType Leaf)) {
        $cmd = "`"$ExeFallback`""
        ([wmiclass]'Win32_Process').Create($cmd) | Out-Null
    }
    else {
        Write-Host "$($script:LogPrefix) WARNING: could not relaunch Discord (unknown path)"
        return
    }

    $settingsPath = Join-Path $env:APPDATA "$AppDataBranch\settings.json"
    $minimizeToTray = $false
    $startMinimized = $false
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
            $minimizeToTray = [bool]$settings.MINIMIZE_TO_TRAY
            $startMinimized = [bool]$settings.START_MINIMIZED
        } catch { }
    }

    if ($startMinimized) {
        Write-Host "$($script:LogPrefix) Discord launched (configured to start minimized)"
        return
    }

    $deadline = (Get-Date).AddSeconds(25)
    $hwnd = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 500
        $curProc = Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Select-Object -First 1
        if ($curProc) { $hwnd = $curProc.MainWindowHandle }
    } while (-not $hwnd -and (Get-Date) -lt $deadline)

    if ($hwnd) {
        if ($minimizeToTray) {
            [Win32]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Write-Host "$($script:LogPrefix) Discord window closed (remains in tray)"
        }
        else {
            $until = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $until) {
                [Win32]::ShowWindow($hwnd, 6) | Out-Null
                Start-Sleep -Seconds 2
                if ([Win32]::IsIconic($hwnd)) {
                    Write-Host "$($script:LogPrefix) Discord minimized at startup"
                    break
                }
                $curProc = Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
                if ($curProc) { $hwnd = $curProc.MainWindowHandle }
            }
        }
    }
}

# -- Main Execution -----------------------------------------------------
if (-not $NoRegister) { Register-GuardianTask }
if (-not $NoNotify) { Register-Aumid }

$StateDir = Join-Path $env:LOCALAPPDATA $script:AppName
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$FailFile = Join-Path $StateDir 'last_fail_date.txt'
$Today = (Get-Date).ToString('yyyy-MM-dd')

if (-not $Force) {
    if (Test-VencordPatch) {
        Write-Host "$($script:LogPrefix) Vencord is already patched and active in Discord. No repair needed."
        exit 0
    }

    if (Test-Path -LiteralPath $FailFile -PathType Leaf) {
        $lastFail = (Get-Content -LiteralPath $FailFile -Raw).Trim()
        if ($lastFail -eq $Today) {
            Write-Host "$($script:LogPrefix) Repair already failed today ($Today). Skipping automatic retries (use -Force to override)."
            exit 0
        }
    }
}

if (-not (Wait-InternetConnection -TimeoutSeconds $script:ConnTimeout)) {
    Write-Warning "$($script:LogPrefix) No internet connection after $($script:ConnTimeout) seconds. Deferring execution to next network/unlock event."
    exit 0
}

$Installer = Get-VencordInstaller
Write-Host "$($script:LogPrefix) Installer: $Installer"

$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Remove-OldLogs -LogDir $LogDir -RetentionDays $script:LogRetentionDays
$LogFile = Join-Path $LogDir ("vencord-guardian-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Start-Transcript -Path $LogFile -Force | Out-Null

$discordProcs = @(Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -notlike '*SystemHelper*' })
$discordWasOpen = $discordProcs.Count -gt 0
$branchRoot = $null
$appDataBranch = 'discord'
$appProcessName = 'Discord.exe'
$appExeFallback = $null

if ($discordWasOpen) {
    Send-Notification -Title $script:AppName -Message 'Discord is closing'
    $main = $discordProcs | Where-Object { $_.Path -and $_.Path -notlike '*SystemHelper*' } | Sort-Object Id | Select-Object -First 1
    if ($main -and $main.Path) {
        $branchRoot = Split-Path (Split-Path $main.Path -Parent) -Parent
        $appDataBranch = (Split-Path $branchRoot -Leaf).ToLowerInvariant()
        $appProcessName = $main.ProcessName + '.exe'
        $appExeFallback = $main.Path
    }
    $discordProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$cleanRoot = if ($branchRoot) { $branchRoot } else { Join-Path $env:LOCALAPPDATA $appDataBranch }
Remove-IncompleteDiscordUpdates -Root $cleanRoot

$proc = Start-Process -FilePath $Installer -ArgumentList '-repair', '-branch', 'auto' -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    Write-Host "$($script:LogPrefix) First attempt failed (exit $($proc.ExitCode)), retrying..."
    Start-Sleep -Seconds 5
    $proc = Start-Process -FilePath $Installer -ArgumentList '-repair', '-branch', 'auto' -Wait -PassThru -NoNewWindow
}

Stop-Transcript | Out-Null

if ($discordWasOpen) {
    Restart-Discord -BranchRoot $branchRoot -ProcessName $appProcessName -ExeFallback $appExeFallback -AppDataBranch $appDataBranch
}

$summary = if ($proc.ExitCode -eq 0) { 'Repair completed (exit 0).' } else { "Repair failed (code $($proc.ExitCode))." }
$state = if ($discordWasOpen) { 'Discord relaunched.' } else { 'Discord was not running.' }
$finalMessage = "$summary $state"

if ($proc.ExitCode -eq 0) {
    if (Test-Path -LiteralPath $FailFile -PathType Leaf) {
        Remove-Item -LiteralPath $FailFile -Force -ErrorAction SilentlyContinue
    }
    Send-Notification -Title $script:AppName -Message 'Vencord repaired'
    Write-AppEvent -Message $finalMessage
}
else {
    Set-Content -LiteralPath $FailFile -Value $Today -Force
    Send-Notification -Title $script:AppName -Message 'Error repairing Vencord' -Icon 'Error'
    Write-AppEvent -Message $finalMessage -Kind 'Error'
}

exit $proc.ExitCode