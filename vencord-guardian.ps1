param(
    [string]$Installer = '',
    [switch]$NoRegister,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'

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

        $escaped = $Message.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
        $binding = '<binding template="ToastGeneric"><text>{0}</text></binding>' -f $escaped
        if ($Icon -eq 'Error') {
            $iconPath = Join-Path $env:TEMP 'vencord-error.ico'
            try {
                Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                $fs = [System.IO.File]::Create($iconPath)
                [System.Drawing.SystemIcons]::Error.Save($fs)
                $fs.Close()
                $binding = '<binding template="ToastGeneric"><text>{0}</text><image placement="appLogoOverride" src="file:///{1}"/></binding>' -f $escaped, ($iconPath -replace '\\', '/')
            }
            catch { }
        }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast><visual>' + $binding + '</visual></toast>')
        $toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('VencordGuardian').Show($toast)
        $sent = $true
    }
    catch { }

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
        catch { }
    }
}

function Get-VencordIcon {
    $dir = Join-Path $env:LOCALAPPDATA 'VencordGuardian'
    $ico = Join-Path $dir 'vencord.ico'
    if (Test-Path -LiteralPath $ico -PathType Leaf) { return $ico }
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $url = 'https://raw.githubusercontent.com/Vencord/Installer/main/winres/icon.ico'
        Write-Host "[vencord] Descargando icono: $url"
        Invoke-WebRequest -Uri $url -OutFile $ico -UseBasicParsing
        if (Test-Path -LiteralPath $ico -PathType Leaf) { return $ico }
    }
    catch {
        Write-Warning "[vencord] No se pudo descargar el icono, se usará el icono por defecto: $($_.Exception.Message)"
    }
    return $null
}

function Ensure-Aumid {
    $aumid = 'VencordGuardian'
    if (Get-StartApps | Where-Object { $_.AppID -eq $aumid }) { return }

    try {
        $lnkName = 'Vencord Guardian'
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $lnkPath = Join-Path $startMenu "$lnkName.lnk"

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        $icon = Get-VencordIcon
        if ($icon) { $shortcut.IconLocation = "$icon,0" }
        $shortcut.Save()

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

        if (-not [AumidHelper]::SetAumid($lnkPath, $aumid)) {
            throw 'No se pudo establecer el AppUserModelID en el acceso directo'
        }
        Write-Host "[vencord] Notificaciones registradas como '$lnkName'"
    }
    catch {
        Write-Warning "[vencord] No se pudo registrar el AUMID, se usará la notificación clásica: $($_.Exception.Message)"
    }
}

function Write-AppEvent {
    param([string]$Message, [string]$Kind = 'Information')
    try {
        New-EventLog -LogName Application -Source 'VencordGuardian' -ErrorAction SilentlyContinue
        $entryType = if ($Kind -eq 'Error') { [System.Diagnostics.EventLogEntryType]::Error } else { [System.Diagnostics.EventLogEntryType]::Information }
        Write-EventLog -LogName Application -Source 'VencordGuardian' -EventId 100 -EntryType $entryType -Message $Message -ErrorAction SilentlyContinue
    }
    catch { }
}

function Ensure-ScheduledTask {
    try {
        $taskName = 'VencordGuardian-Daily'
        $taskPath = $PSCommandPath
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $needsUpdate = -not $task
        if ($task) {
            $currentArg = $task.Actions | Select-Object -ExpandProperty Arguments
            $needsUpdate = $currentArg -notcontains $null -and -not ($currentArg -and $currentArg.Contains($taskPath))
        }

        if ($needsUpdate) {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$taskPath`""
            $trigger = New-ScheduledTaskTrigger -Daily -At 07:00
            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Repara/actualiza Vencord diariamente a las 7:00' -Force | Out-Null
            Write-Host '[vencord] Tarea programada VencordGuardian-Daily creada/actualizada'
        }
    }
    catch {
        Write-Warning "[vencord] No se pudo asegurar la tarea programada: $($_.Exception.Message)"
    }
}

function Get-VencordInstaller {
    if ($Installer) {
        if (Test-Path -LiteralPath $Installer -PathType Leaf) { return $Installer }
        throw "Instalador no encontrado: $Installer"
    }

    $candidates = @(
        (Join-Path $PSScriptRoot 'VencordInstallerCli.exe'),
        (Join-Path $env:USERPROFILE 'Downloads\VencordInstallerCli.exe'),
        (Join-Path $env:USERPROFILE 'Desktop\VencordInstallerCli.exe'),
        (Join-Path $env:TEMP 'VencordInstallerCli.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

    if ($candidates) { return $candidates }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $target = Join-Path $env:TEMP 'VencordInstallerCli.exe'
    $url = 'https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe'
    Write-Host "[vencord] Descargando instalador: $url"
    Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'No se pudo descargar el instalador de Vencord' }
    return $target
}

$Installer = Get-VencordInstaller
"[vencord] Instalador: $Installer"

if (-not $NoRegister) { Ensure-ScheduledTask }
if (-not $NoNotify) { Ensure-Aumid }

$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("vencord-guardian-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Start-Transcript -Path $LogFile -Force | Out-Null

$discordProcs = @(Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -notlike '*SystemHelper*' })
$discordWasOpen = $discordProcs.Count -gt 0
$branchRoot = $null
$appDataBranch = 'discord'
$appProcessName = 'Discord.exe'
$appExeFallback = $null

if ($discordWasOpen) {
    Send-Notification -Title 'Vencord Guardian' -Message 'Discord va a cerrarse'
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

$proc = Start-Process -FilePath $Installer -ArgumentList '-repair', '-branch', 'auto' -Wait -PassThru -NoNewWindow

Stop-Transcript | Out-Null

if ($discordWasOpen) {
    $updateExe = Join-Path $branchRoot 'Update.exe'
    if (Test-Path -LiteralPath $updateExe -PathType Leaf) {
        Start-Process -FilePath $updateExe -ArgumentList '--processStart', $appProcessName
    }
    elseif ($appExeFallback) {
        Start-Process -FilePath $appExeFallback
    }
    else {
        Write-Host "[vencord] AVISO: no se pudo relanzar Discord (ruta desconocida)"
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@

    $deadline = (Get-Date).AddSeconds(25)
    do {
        Start-Sleep -Milliseconds 500
        $hwnd = (Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
    } while (-not $hwnd -and (Get-Date) -lt $deadline)

    if ($hwnd) {
        $settingsPath = Join-Path $env:APPDATA "$appDataBranch\settings.json"
        $minimizeToTray = $false
        if (Test-Path -LiteralPath $settingsPath) {
            $minimizeToTray = [bool]((Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).MINIMIZE_TO_TRAY)
        }

        if ($minimizeToTray) {
            $until = (Get-Date).AddSeconds(25)
            $noWindowStreak = 0
            while ((Get-Date) -lt $until -and $noWindowStreak -lt 4) {
                $cur = (Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
                if ($cur) {
                    [Win32]::PostMessage($cur.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    $noWindowStreak = 0
                }
                else { $noWindowStreak++ }
                Start-Sleep -Milliseconds 700
            }
            Write-Host '[vencord] Ventana de Discord cerrada (sigue en la bandeja)'
        }
        else {
            $until = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $until) {
                [Win32]::ShowWindow($hwnd, 6) | Out-Null
                Start-Sleep -Seconds 3
                if ([Win32]::IsIconic($hwnd)) {
                    Start-Sleep -Seconds 4
                    if ([Win32]::IsIconic($hwnd)) { Write-Host '[vencord] Discord minimizado al iniciar'; break }
                }
                else {
                    $hwnd = (Get-Process -Name 'Discord*' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
                }
            }
        }
    }
}

$summary = if ($proc.ExitCode -eq 0) { "Reparación completada (exit 0)." } else { "Reparación falló (código $($proc.ExitCode))." }
$state = if ($discordWasOpen) { 'Discord relanzado.' } else { 'Discord no estaba abierto.' }
$finalMessage = "$summary $state"

if ($proc.ExitCode -eq 0) {
    Send-Notification -Title 'Vencord Guardian' -Message 'Vencord reparado'
    Write-AppEvent -Message $finalMessage
}
else {
    Send-Notification -Title 'Vencord Guardian' -Message 'Error reparando Vencord' -Icon 'Error'
    Write-AppEvent -Message $finalMessage -Kind 'Error'
}

exit $proc.ExitCode