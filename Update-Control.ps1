#Requires -Version 5.1
<#
.SYNOPSIS
    Controls Windows Update and browser auto-updates (Edge, Chrome, Firefox) on Windows 10/11.

.DESCRIPTION
    Built to stop many PCs from saturating the office internet link when they all start
    updating at the same time (start of the work day).

    Two modes are available:
      Disable  - turns automatic updates off (Windows Update, Delivery Optimization,
                 Microsoft Store auto-updates, Edge, Chrome and Firefox updaters).
      Throttle - keeps updates on, but limits their bandwidth and sets active hours.

    Every change is recorded (original values, service start types, scheduled task states,
    Firefox policies.json) in C:\ProgramData\UpdateControl\state.json so that -Revert can
    restore the PC to its previous state. Every action is written to a log file.

    The script does not store or ask for any credentials. Open PowerShell "as Administrator"
    and run it from there.

.PARAMETER Mode
    Disable  : turn automatic updates off (see DESCRIPTION).
    Throttle : keep updates on, limit bandwidth, set active hours (browsers are not changed).

.PARAMETER ThrottlePercent
    Bandwidth percentage (5-100) used by -Mode Throttle. Default: 20.

.PARAMETER Revert
    Restore everything this script changed, using the saved state file.

.PARAMETER Status
    Show the current state of the related services and policies. Changes nothing.

.PARAMETER Help
    Show the built-in help text. Aliases: -h, --help. Does not need Administrator rights.

.EXAMPLE
    .\Update-Control.ps1 -Mode Disable
    Turns off Windows Update and the Edge/Chrome/Firefox auto-updaters.

.EXAMPLE
    .\Update-Control.ps1 -Mode Throttle -ThrottlePercent 30
    Keeps updates on but limits their bandwidth to 30 percent.

.EXAMPLE
    .\Update-Control.ps1 -Revert
    Undoes all changes made by this script.

.NOTES
    Name        : Update-Control.ps1
    Author      : A. Ghahremani
    Version     : 1.0.0
    Created     : 2026-10-17
    Last update : 2026-10-17
    Requires    : Windows 10/11, Windows PowerShell 5.1 or later, run as Administrator
    Log file    : C:\ProgramData\UpdateControl\update-control.log
    State file  : C:\ProgramData\UpdateControl\state.json

    Changelog
      1.0.0 (2026-10-17) Initial release: Disable / Throttle / Revert / Status / Help,
                         SYSTEM fallback for protected scheduled tasks, logging.

    DISCLAIMER
      Provided "as is", without warranty. Disabling updates means the PC receives no
      security patches. Test on one PC first and plan a manual update window.
#>
[CmdletBinding()]
param(
    [ValidateSet('Disable', 'Throttle')][string]$Mode,
    [switch]$Revert,
    [switch]$Status,
    [ValidateRange(5, 100)][int]$ThrottlePercent = 20,
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Continue'
$ScriptVersion = '1.0.0'

$WorkDir   = Join-Path $env:ProgramData 'UpdateControl'
$BackupDir = Join-Path $WorkDir 'Backup'
$LogFile   = Join-Path $WorkDir 'update-control.log'
$StateFile = Join-Path $WorkDir 'state.json'

# ------------------------------------------------------------------
# Help
# ------------------------------------------------------------------
function Show-Help {
    $lines = @(
        '',
        "Update-Control.ps1  (version $ScriptVersion)",
        'Controls Windows Update and the auto-update of Edge, Chrome and Firefox on Windows 10/11.',
        'Must be run from a PowerShell window opened as Administrator.',
        '',
        'USAGE',
        '  .\Update-Control.ps1 -Mode Disable',
        '  .\Update-Control.ps1 -Mode Throttle [-ThrottlePercent 20]',
        '  .\Update-Control.ps1 -Revert',
        '  .\Update-Control.ps1 -Status',
        '  .\Update-Control.ps1 -Help          (also: -h, --help)',
        '',
        'FLAGS',
        '  -Mode Disable',
        '      Turns OFF automatic updates completely:',
        '        * Windows Update policies (NoAutoUpdate, AUOptions=notify never, no driver updates)',
        '        * Services: wuauserv, UsoSvc, WaaSMedicSvc, DoSvc',
        '        * Scheduled tasks: UpdateOrchestrator, WindowsUpdate, WaaSMedic',
        '        * Delivery Optimization set to HTTP-only (no peer-to-peer)',
        '        * Microsoft Store automatic app updates',
        '        * Edge:    policies, services edgeupdate/edgeupdatem, MicrosoftEdgeUpdate* tasks',
        '        * Chrome:  policies, services gupdate/gupdatem, GoogleUpdateTaskMachine* tasks',
        '        * Firefox: policy DisableAppUpdate, policies.json, service MozillaMaintenance, \Mozilla tasks',
        '      Protected tasks that deny Administrators are disabled through a temporary SYSTEM task.',
        '',
        '  -Mode Throttle',
        '      Keeps updates ON but limits their bandwidth:',
        '        * Delivery Optimization: LAN peering, background/foreground bandwidth limit',
        '        * Active hours 08:00-18:00 (no automatic restarts in that window)',
        '      Browsers are NOT changed in this mode.',
        '',
        '  -ThrottlePercent <5-100>',
        '      Bandwidth percentage used with -Mode Throttle. Default: 20.',
        '',
        '  -Revert',
        '      Restores everything this script changed (registry values, service start types,',
        '      scheduled tasks, Firefox policies.json) from the saved state file.',
        '',
        '  -Status',
        '      Only shows the current state (services, policies). Changes nothing.',
        '',
        '  -Help, -h, --help',
        '      Shows this text. Does not need Administrator rights.',
        '',
        'FILES',
        "  Log file   : $LogFile",
        "  State file : $StateFile   (original values, used by -Revert)",
        "  Backups    : $BackupDir",
        '',
        'NOTES',
        '  * Running -Mode Disable twice is safe: original values are saved only once.',
        '  * Reboot after -Mode Disable or -Revert.',
        '  * Disabled updates mean no security patches. Plan a manual update window.',
        ''
    )
    $lines | ForEach-Object { Write-Host $_ }
}

$wantsHelp = $Help
foreach ($r in @($Rest)) {
    if ($r -in @('--help', '-help', '-h', '/?', '/h', '/help', 'help')) { $wantsHelp = $true }
}
if ($wantsHelp) { Show-Help; exit 0 }

$unknown = @($Rest | Where-Object { $_ })
if ($unknown.Count -gt 0) {
    Write-Host "Unknown argument(s): $($unknown -join ' ')" -ForegroundColor Red
    Show-Help
    exit 1
}

# ------------------------------------------------------------------
# Admin check (no credentials, no auto-elevation)
# ------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host 'ERROR: this script must run in a PowerShell window opened as Administrator.' -ForegroundColor Red
    Write-Host '       (Start menu > PowerShell > right click > Run as administrator)'
    exit 1
}

if (-not $Revert -and -not $Status -and -not $Mode) {
    Write-Host 'ERROR: choose one of -Mode Disable, -Mode Throttle, -Revert or -Status.' -ForegroundColor Red
    Show-Help
    exit 1
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

# ------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------
$script:WarnCount = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -eq 'WARN') { $script:WarnCount++ }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------
# State (original values, used by -Revert)
# ------------------------------------------------------------------
$script:State = @{ Registry = @(); Services = @(); Tasks = @(); Files = @() }

function Load-State {
    if (Test-Path $StateFile) {
        try {
            $o = Get-Content $StateFile -Raw | ConvertFrom-Json
            foreach ($k in @('Registry', 'Services', 'Tasks', 'Files')) {
                if ($o.$k) { $script:State[$k] = @($o.$k) } else { $script:State[$k] = @() }
            }
        }
        catch { Write-Log "Could not read state file: $($_.Exception.Message)" 'WARN' }
    }
}

function Save-State {
    $script:State | ConvertTo-Json -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
}

# ------------------------------------------------------------------
# Protected service keys (e.g. WaaSMedicSvc): take ownership
# ------------------------------------------------------------------
if (-not ('UC.Priv' -as [type])) {
    Add-Type -Namespace UC -Name Priv -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int RtlAdjustPrivilege(int Privilege, bool Enable, bool CurrentThread, out bool Enabled);
'@
}

function Grant-ServiceKeyAccess {
    param([string]$Name)
    $o = $false
    [UC.Priv]::RtlAdjustPrivilege(9, $true, $false, [ref]$o)  | Out-Null   # SeTakeOwnershipPrivilege
    [UC.Priv]::RtlAdjustPrivilege(18, $true, $false, [ref]$o) | Out-Null   # SeRestorePrivilege
    [UC.Priv]::RtlAdjustPrivilege(17, $true, $false, [ref]$o) | Out-Null   # SeBackupPrivilege
    $sub    = "SYSTEM\CurrentControlSet\Services\$Name"
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    $acl = New-Object System.Security.AccessControl.RegistrySecurity
    $acl.SetOwner($admins)
    $key.SetAccessControl($acl)
    $key.Close()

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
    $acl  = $key.GetAccessControl()
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')
    $acl.SetAccessRule($rule)
    $key.SetAccessControl($acl)
    $key.Close()
}

# ------------------------------------------------------------------
# Registry helpers
# ------------------------------------------------------------------
function Set-RegPolicy {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $rec = $script:State.Registry | Where-Object { $_.Path -eq $Path -and $_.Name -eq $Name }
    if (-not $rec) {
        $existed = $false; $old = $null; $oldType = $null
        if (Test-Path $Path) {
            $k = Get-Item $Path
            if ($k.GetValueNames() -contains $Name) {
                $existed = $true
                $old     = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $oldType = $k.GetValueKind($Name).ToString()
            }
        }
        $script:State.Registry += [pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existed; Value = $old; Type = $oldType }
    }
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        Write-Log "Registry set: $Path\$Name = $Value"
    }
    catch { Write-Log "Could not set $Path\$Name : $($_.Exception.Message)" 'WARN' }
}

function Restore-RegPolicies {
    foreach ($r in $script:State.Registry) {
        try {
            if ($r.Existed) {
                if (-not (Test-Path $r.Path)) { New-Item -Path $r.Path -Force | Out-Null }
                Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type -ErrorAction Stop
                Write-Log "Registry restored: $($r.Path)\$($r.Name) = $($r.Value)"
            }
            else {
                Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue
                Write-Log "Registry value removed: $($r.Path)\$($r.Name)"
            }
        }
        catch { Write-Log "Registry restore failed for $($r.Path)\$($r.Name): $($_.Exception.Message)" 'WARN' }
    }
}

# ------------------------------------------------------------------
# Service helpers
# ------------------------------------------------------------------
function Disable-SvcSafe {
    param([string]$Name)
    $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $svcKey)) { Write-Log "Service not found, skipping: $Name"; return }

    $props = Get-ItemProperty $svcKey
    if (-not ($script:State.Services | Where-Object { $_.Name -eq $Name })) {
        $delayed = $null
        if ($props.PSObject.Properties['DelayedAutostart']) { $delayed = $props.DelayedAutostart }
        $script:State.Services += [pscustomobject]@{ Name = $Name; Start = $props.Start; Delayed = $delayed }
    }

    try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch { }

    try {
        Set-ItemProperty -Path $svcKey -Name 'Start' -Value 4 -ErrorAction Stop
        Write-Log "Service disabled: $Name"
    }
    catch {
        try {
            Grant-ServiceKeyAccess -Name $Name
            Set-ItemProperty -Path $svcKey -Name 'Start' -Value 4 -ErrorAction Stop
            Write-Log "Service disabled (after taking ownership of key): $Name"
        }
        catch { Write-Log "Could not disable service $Name : $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-Services {
    foreach ($s in $script:State.Services) {
        $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Name)"
        if (-not (Test-Path $svcKey)) { continue }
        try {
            try { Set-ItemProperty -Path $svcKey -Name 'Start' -Value $s.Start -ErrorAction Stop }
            catch {
                Grant-ServiceKeyAccess -Name $s.Name
                Set-ItemProperty -Path $svcKey -Name 'Start' -Value $s.Start -ErrorAction Stop
            }
            if ($null -ne $s.Delayed) {
                Set-ItemProperty -Path $svcKey -Name 'DelayedAutostart' -Value $s.Delayed -ErrorAction SilentlyContinue
            }
            Write-Log "Service restored: $($s.Name) (Start=$($s.Start))"
            if ($s.Start -eq 2) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
        }
        catch { Write-Log "Could not restore service $($s.Name): $($_.Exception.Message)" 'WARN' }
    }
}

# ------------------------------------------------------------------
# Scheduled task helpers
# Some tasks (e.g. UpdateOrchestrator\Schedule Scan) are owned by SYSTEM and even an
# Administrator gets "Access is denied". Fallback: run the change once as SYSTEM through
# a temporary scheduled task, then delete that temporary task.
# ------------------------------------------------------------------
function Set-TaskStateAsSystem {
    param([string]$TaskPath, [string]$TaskName, [ValidateSet('Disable', 'Enable')][string]$Action)
    $tmpName = 'UC_' + [guid]::NewGuid().ToString('N')
    try {
        $cmd = "$Action-ScheduledTask -TaskPath '$TaskPath' -TaskName '$TaskName' | Out-Null"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
        $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $tmpName -Action $act -Principal $pri -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tmpName -ErrorAction Stop
        Start-Sleep -Seconds 2
        for ($i = 0; $i -lt 20; $i++) {
            $st = (Get-ScheduledTask -TaskName $tmpName -ErrorAction SilentlyContinue).State
            if ($st -ne 'Running') { break }
            Start-Sleep -Seconds 1
        }
    }
    catch { Write-Log "SYSTEM fallback failed for $TaskPath$TaskName : $($_.Exception.Message)" 'WARN' }
    finally {
        Unregister-ScheduledTask -TaskName $tmpName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $after = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $after) { return $false }
    if ($Action -eq 'Disable') { return ($after.State -eq 'Disabled') }
    return ($after.State -ne 'Disabled')
}

function Disable-TaskList {
    param($Tasks)
    foreach ($t in @($Tasks)) {
        if (-not $t) { continue }
        if ($t.State -eq 'Disabled') { continue }
        if (-not ($script:State.Tasks | Where-Object { $_.TaskPath -eq $t.TaskPath -and $_.TaskName -eq $t.TaskName })) {
            $script:State.Tasks += [pscustomobject]@{ TaskPath = $t.TaskPath; TaskName = $t.TaskName }
        }
        try {
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Write-Log "Task disabled: $($t.TaskPath)$($t.TaskName)"
        }
        catch {
            if (Set-TaskStateAsSystem -TaskPath $t.TaskPath -TaskName $t.TaskName -Action 'Disable') {
                Write-Log "Task disabled (via SYSTEM): $($t.TaskPath)$($t.TaskName)"
            }
            else {
                Write-Log "Could not disable task $($t.TaskPath)$($t.TaskName): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Restore-Tasks {
    foreach ($t in $script:State.Tasks) {
        try {
            Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Write-Log "Task re-enabled: $($t.TaskPath)$($t.TaskName)"
        }
        catch {
            if (Set-TaskStateAsSystem -TaskPath $t.TaskPath -TaskName $t.TaskName -Action 'Enable') {
                Write-Log "Task re-enabled (via SYSTEM): $($t.TaskPath)$($t.TaskName)"
            }
            else {
                Write-Log "Could not re-enable task $($t.TaskPath)$($t.TaskName): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# ------------------------------------------------------------------
# Firefox policies.json
# ------------------------------------------------------------------
function Set-FirefoxPoliciesJson {
    $dirs = @("$env:ProgramFiles\Mozilla Firefox", "${env:ProgramFiles(x86)}\Mozilla Firefox") |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'firefox.exe')) }
    if (-not $dirs) { Write-Log 'Firefox install folder not found, policies.json skipped.' }
    foreach ($dir in $dirs) {
        $dist = Join-Path $dir 'distribution'
        $pj   = Join-Path $dist 'policies.json'
        if (-not ($script:State.Files | Where-Object { $_.Path -eq $pj })) {
            if (Test-Path $pj) {
                $bk = Join-Path $BackupDir ('policies_' + [guid]::NewGuid().ToString('N') + '.json')
                Copy-Item $pj $bk -Force
                $script:State.Files += [pscustomobject]@{ Path = $pj; BackupPath = $bk; CreatedByUs = $false }
            }
            else {
                $script:State.Files += [pscustomobject]@{ Path = $pj; BackupPath = $null; CreatedByUs = $true }
            }
        }
        try {
            New-Item -ItemType Directory -Path $dist -Force | Out-Null
            if (Test-Path $pj) { $j = Get-Content $pj -Raw | ConvertFrom-Json } else { $j = [pscustomobject]@{} }
            if (-not $j.PSObject.Properties['policies']) {
                Add-Member -InputObject $j -NotePropertyName 'policies' -NotePropertyValue ([pscustomobject]@{})
            }
            if ($j.policies.PSObject.Properties['DisableAppUpdate']) { $j.policies.DisableAppUpdate = $true }
            else { Add-Member -InputObject $j.policies -NotePropertyName 'DisableAppUpdate' -NotePropertyValue $true }
            [IO.File]::WriteAllText($pj, ($j | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            Write-Log "Firefox policies.json updated: $pj"
        }
        catch { Write-Log "Could not update $pj : $($_.Exception.Message)" 'WARN' }
    }
}

function Restore-Files {
    foreach ($f in $script:State.Files) {
        try {
            if ($f.CreatedByUs) {
                Remove-Item $f.Path -Force -ErrorAction SilentlyContinue
                $d = Split-Path $f.Path
                if ((Test-Path $d) -and -not (Get-ChildItem $d -Force -ErrorAction SilentlyContinue)) { Remove-Item $d -Force -ErrorAction SilentlyContinue }
                Write-Log "File removed: $($f.Path)"
            }
            elseif ($f.BackupPath -and (Test-Path $f.BackupPath)) {
                Copy-Item $f.BackupPath $f.Path -Force
                Write-Log "File restored: $($f.Path)"
            }
        }
        catch { Write-Log "Could not restore $($f.Path): $($_.Exception.Message)" 'WARN' }
    }
}

# ------------------------------------------------------------------
# Mode: Disable
# ------------------------------------------------------------------
function Invoke-Disable {
    Write-Log '=== Mode: Disable ==='

    Write-Log '--- Windows Update ---'
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$wu\AU"
    Set-RegPolicy $au 'NoAutoUpdate' 1
    Set-RegPolicy $au 'AUOptions' 1
    Set-RegPolicy $wu 'ExcludeWUDriversInQualityUpdate' 1
    Set-RegPolicy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
    Set-RegPolicy 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

    foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc')) { Disable-SvcSafe $svc }

    foreach ($p in @('\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\WaaSMedic\')) {
        Disable-TaskList (Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)
    }

    Write-Log '--- Microsoft Edge ---'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    Set-RegPolicy $edge 'UpdateDefault' 0
    Set-RegPolicy $edge 'AutoUpdateCheckPeriodMinutes' 0
    Set-RegPolicy $edge 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0
    foreach ($svc in @('edgeupdate', 'edgeupdatem')) { Disable-SvcSafe $svc }
    Disable-TaskList (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdate*' })
    Get-Process -Name 'MicrosoftEdgeUpdate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Log '--- Google Chrome ---'
    $chrome = 'HKLM:\SOFTWARE\Policies\Google\Update'
    Set-RegPolicy $chrome 'UpdateDefault' 0
    Set-RegPolicy $chrome 'AutoUpdateCheckPeriodMinutes' 0
    Set-RegPolicy $chrome 'DisableAutoUpdateChecksCheckboxValue' 1
    Set-RegPolicy $chrome 'Update{8A69D345-D564-463C-AFF1-A69D9E530F96}' 0
    foreach ($svc in @('gupdate', 'gupdatem')) { Disable-SvcSafe $svc }
    Disable-TaskList (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'GoogleUpdateTaskMachine*' })
    Get-Process -Name 'GoogleUpdate' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Write-Log '--- Mozilla Firefox ---'
    Set-RegPolicy 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableAppUpdate' 1
    Disable-SvcSafe 'MozillaMaintenance'
    Disable-TaskList (Get-ScheduledTask -TaskPath '\Mozilla\' -ErrorAction SilentlyContinue)
    Set-FirefoxPoliciesJson

    Save-State
    Write-Log 'Done. A reboot is recommended. Use -Revert to undo everything.'
}

# ------------------------------------------------------------------
# Mode: Throttle
# ------------------------------------------------------------------
function Invoke-Throttle {
    Write-Log "=== Mode: Throttle ($ThrottlePercent%) ==="
    $do = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    Set-RegPolicy $do 'DODownloadMode' 1
    Set-RegPolicy $do 'DOPercentageMaxBackgroundBandwidth' $ThrottlePercent
    Set-RegPolicy $do 'DOPercentageMaxForegroundBandwidth' $ThrottlePercent

    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Set-RegPolicy $wu 'SetActiveHours' 1
    Set-RegPolicy $wu 'ActiveHoursStart' 8
    Set-RegPolicy $wu 'ActiveHoursEnd' 18

    Save-State
    Write-Log 'Done. Updates remain enabled but bandwidth is limited. Use -Revert to undo.'
}

# ------------------------------------------------------------------
# Revert
# ------------------------------------------------------------------
function Invoke-Revert {
    Write-Log '=== Revert ==='
    if (-not (Test-Path $StateFile)) { Write-Log 'No state file found. Nothing to revert.' 'WARN'; return }
    Restore-RegPolicies
    Restore-Services
    Restore-Tasks
    Restore-Files
    Move-Item $StateFile ($StateFile + '.reverted_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) -Force
    Write-Log 'Revert complete. A reboot is recommended.'
}

# ------------------------------------------------------------------
# Status (read only)
# ------------------------------------------------------------------
function Show-Status {
    Write-Log '=== Status (read only) ==='
    $startNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'edgeupdate', 'edgeupdatem', 'gupdate', 'gupdatem', 'MozillaMaintenance')) {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (Test-Path $k) {
            $s  = (Get-ItemProperty $k).Start
            $rt = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status
            Write-Log ("Service {0,-20} Start={1,-9} Status={2}" -f $svc, $startNames[[int]$s], $rt)
        }
        else { Write-Log ("Service {0,-20} not installed" -f $svc) }
    }
    $checks = @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoUpdate'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization', 'DODownloadMode'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate', 'UpdateDefault'),
        @('HKLM:\SOFTWARE\Policies\Google\Update', 'UpdateDefault'),
        @('HKLM:\SOFTWARE\Policies\Mozilla\Firefox', 'DisableAppUpdate')
    )
    foreach ($c in $checks) {
        $v = $null
        if (Test-Path $c[0]) { $v = (Get-ItemProperty $c[0] -ErrorAction SilentlyContinue).$($c[1]) }
        if ($null -eq $v) { $v = '(not set)' }
        Write-Log ("Policy  {0}\{1} = {2}" -f $c[0], $c[1], $v)
    }
    if (Test-Path $StateFile) { Write-Log "State file exists: $StateFile (changes were applied by this script)" }
    else { Write-Log 'No state file: this script has not changed anything on this PC.' }
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
Write-Log "Update-Control v$ScriptVersion started on $env:COMPUTERNAME by $env:USERNAME"
Load-State

if ($Status) { Show-Status }
elseif ($Revert) { Invoke-Revert }
elseif ($Mode -eq 'Disable') { Invoke-Disable }
elseif ($Mode -eq 'Throttle') { Invoke-Throttle }

if ($script:WarnCount -gt 0) { Write-Log "Finished with $($script:WarnCount) warning(s). See the log for details." 'WARN' }
else { Write-Log 'Finished with no warnings.' }
Write-Log "Log file: $LogFile"
