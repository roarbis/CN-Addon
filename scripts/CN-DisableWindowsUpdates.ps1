#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Locks down Windows Update on a CN Hub so automatic updates cannot reboot or
  corrupt the Home Assistant VM during live operation.

.DESCRIPTION
  Run ONCE after completing a full round of Windows Updates on the hub.
  Applies a layered defence:
    1. Pause updates via registry (feature + quality, ~2.85 years / 1042 days)
    2. Group Policy registry keys — no auto-restart, no auto-update, no reboot
       with logged-on users
    3. Disable Delivery Optimisation peer-to-peer (HTTP only)
    4. Set Windows Update + Update Orchestrator services to Manual startup
    5. Disable Update Orchestrator scheduled tasks
    6. Lock to current Windows feature version (no OS version upgrades)
    7. Mark the Ethernet adapter as metered (belt-and-braces — WU won't
       auto-download on metered connections)

.PARAMETER DeferDays
  How many days to pause updates for. Default 1042 (~2.85 years, which is the
  value Windows reads from FlightSettingsMaxPauseDays). Max meaningful value
  is 7300 (20 years) but Windows UI caps display at 1042 — the registry itself
  accepts any value.

.PARAMETER SkipMetered
  Skip the metered-connection setting (use if adapter will be changed later).

.EXAMPLE
  # Dry run — shows every change, makes NONE:
  .\CN-DisableWindowsUpdates.ps1 -WhatIf

.EXAMPLE
  # Live run with defaults (1042-day pause):
  .\CN-DisableWindowsUpdates.ps1

.EXAMPLE
  # Live run, 20-year pause:
  .\CN-DisableWindowsUpdates.ps1 -DeferDays 7300

.NOTES
  To RE-ENABLE updates (e.g. when doing a deliberate update cycle):
    1. Run this script with -Undo
    2. Open Windows Update and check for updates manually
    3. After updates complete, re-run this script without -Undo

  Author   : Connect Nest (product: ConnectHub)
  Requires : Windows 10/11, PowerShell 5.1+, Administrator
  Version  : 1.1 (2026-04-22)
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [int]   $DeferDays   = 1042,
    [switch]$SkipMetered,
    [switch]$Undo
)

$ESC = [char]27
function Write-OK   ($m) { Write-Host "${ESC}[92m  [OK]  $m${ESC}[0m" }
function Write-Warn ($m) { Write-Host "${ESC}[93m  [!!]  $m${ESC}[0m" }
function Write-Info ($m) { Write-Host "${ESC}[37m        $m${ESC}[0m" }
function Write-Head ($m) {
    $line = '-' * 60
    Write-Host "${ESC}[96m`n$line`n  $m`n$line${ESC}[0m"
}

function Set-RegValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    if ($PSCmdlet.ShouldProcess("$Path\$Name = $Value ($Type)", "Set registry value")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    }
}
function Remove-RegValue {
    param($Path, $Name)
    if (Test-Path $Path) {
        if ($PSCmdlet.ShouldProcess("$Path\$Name", "Remove registry value")) {
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        }
    }
}
function Set-Svc {
    param($Name, $StartType)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warn "Service '$Name' not found — skipping"; return }
    if ($PSCmdlet.ShouldProcess("Service '$Name'", "Set StartupType=$StartType")) {
        Set-Service -Name $Name -StartupType $StartType -ErrorAction SilentlyContinue
        if ($StartType -eq 'Manual' -or $StartType -eq 'Disabled') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Write-OK "Service '$Name' -> $StartType"
    }
}
function Set-Task {
    param($Path, $Disable)
    $task = Get-ScheduledTask -TaskPath $Path -ErrorAction SilentlyContinue
    if (-not $task) { return }
    foreach ($t in $task) {
        $action = if ($Disable) { "Disable" } else { "Enable" }
        if ($PSCmdlet.ShouldProcess("Task '$($t.TaskName)'", $action)) {
            if ($Disable) { $t | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
            else          { $t | Enable-ScheduledTask  -ErrorAction SilentlyContinue | Out-Null }
            Write-OK "Task '$($t.TaskName)' -> $action'd"
        }
    }
}

# ── Undo mode ────────────────────────────────────────────────────────────────
if ($Undo) {
    Write-Head "CN-DisableWindowsUpdates — UNDO (re-enabling updates)"
    $uxKey  = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $wuKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $auKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $doKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    foreach ($n in @('PauseFeatureUpdatesStartTime','PauseFeatureUpdatesEndTime',
                     'PauseQualityUpdatesStartTime','PauseQualityUpdatesEndTime',
                     'FlightSettingsMaxPauseDays')) { Remove-RegValue $uxKey $n }
    foreach ($n in @('NoAutoRebootWithLoggedOnUsers','NoAutoUpdate','AUOptions',
                     'TargetReleaseVersion','TargetReleaseVersionInfo')) {
        Remove-RegValue $wuKey $n; Remove-RegValue $auKey $n
    }
    Remove-RegValue $doKey 'DODownloadMode'
    Set-Svc 'wuauserv' 'Automatic'
    Set-Svc 'UsoSvc'   'Automatic'
    Set-Task '\Microsoft\Windows\UpdateOrchestrator\' $false
    Write-Head "Done — run Windows Update manually then re-apply CN-DisableWindowsUpdates.ps1"
    exit 0
}

# ── Banner ───────────────────────────────────────────────────────────────────
Write-Head "CN Hub — Disable Windows Updates (${DeferDays}-day pause)"
Write-Info "IMPORTANT: Run Windows Update manually BEFORE this script."
Write-Info "Make sure all pending updates are installed and the machine is rebooted."
Write-Info "Then run this script to lock it down."
Write-Info ""

$now    = Get-Date
$expiry = $now.AddDays($DeferDays)
$nowStr = $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$expStr = $expiry.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ── 1. Pause feature + quality updates via UX settings ───────────────────────
Write-Head "1. Pausing updates for $DeferDays days (until $($expiry.ToString('yyyy-MM-dd')))"
$uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
Set-RegValue $uxPath 'FlightSettingsMaxPauseDays'       $DeferDays
Set-RegValue $uxPath 'PauseFeatureUpdatesStartTime'     $nowStr    'String'
Set-RegValue $uxPath 'PauseFeatureUpdatesEndTime'       $expStr    'String'
Set-RegValue $uxPath 'PauseQualityUpdatesStartTime'     $nowStr    'String'
Set-RegValue $uxPath 'PauseQualityUpdatesEndTime'       $expStr    'String'
Write-OK "Update pause set: $nowStr -> $expStr"

# ── 2. Group Policy — no auto-update, no auto-reboot ─────────────────────────
Write-Head "2. Applying Group Policy registry keys"
$wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

# NoAutoRebootWithLoggedOnUsers — prevents forced reboots while anyone is logged in
Set-RegValue $auPath 'NoAutoRebootWithLoggedOnUsers' 1
Write-OK "NoAutoRebootWithLoggedOnUsers = 1"

# NoAutoUpdate — disables automatic download and install
Set-RegValue $auPath 'NoAutoUpdate' 1
Write-OK "NoAutoUpdate = 1"

# AUOptions = 1 — never check for updates automatically
# Values: 2=notify, 3=auto-download+notify, 4=auto-download+schedule, 1=disabled
Set-RegValue $auPath 'AUOptions' 1
Write-OK "AUOptions = 1 (disabled)"

# Prevent auto-restart for scheduled installs
Set-RegValue $auPath 'NoAutoRebootWithLoggedOnUsers' 1
Set-RegValue $wuPath 'SetAutoRestartNotificationDisable' 1
Write-OK "Auto-restart notifications disabled"

# ── 3. Lock to current Windows version (no surprise OS upgrades) ─────────────
Write-Head "3. Locking to current Windows feature version"
try {
    $verInfo = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    $curVer  = $verInfo.DisplayVersion   # e.g. "23H2"
    if (-not $curVer) { $curVer = $verInfo.ReleaseId }
    Set-RegValue $wuPath 'TargetReleaseVersion'     1
    Set-RegValue $wuPath 'TargetReleaseVersionInfo' $curVer 'String'
    Write-OK "Locked to Windows version: $curVer"
} catch {
    Write-Warn "Could not read current Windows version — skipping version lock"
}

# ── 4. Delivery Optimisation — HTTP only, no peer downloads ──────────────────
Write-Head "4. Disabling Delivery Optimisation peer downloads"
$doPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
# DODownloadMode: 0=HTTP only, 1=LAN, 2=LAN+Internet, 3=Internet, 99=Bypass, 100=Simple
Set-RegValue $doPath 'DODownloadMode' 0
Write-OK "Delivery Optimisation -> HTTP only (no P2P)"

# ── 5. Services — set to Manual ──────────────────────────────────────────────
Write-Head "5. Setting update services to Manual (prevents auto-start)"
Write-Info "Using Manual (not Disabled) — Disabled can break OS internals."
Set-Svc 'wuauserv' 'Manual'   # Windows Update
Set-Svc 'UsoSvc'   'Manual'   # Update Orchestrator Service (the real driver in Win11)
Set-Svc 'WaaSMedicSvc' 'Manual'   # Windows Update Medic (tries to self-heal WU)

# ── 6. Scheduled tasks — disable Update Orchestrator ─────────────────────────
Write-Head "6. Disabling Update Orchestrator scheduled tasks"
Set-Task '\Microsoft\Windows\UpdateOrchestrator\' $true
Set-Task '\Microsoft\Windows\WindowsUpdate\'      $true

# ── 7. Metered connection (optional) ─────────────────────────────────────────
if (-not $SkipMetered) {
    Write-Head "7. Marking primary Ethernet adapter as metered"
    Write-Info "WU will not auto-download on metered connections."
    try {
        $metKeyRel = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost'
        $metKeyPS  = "HKLM:\$metKeyRel"

        # DefaultMediaCost is owned by TrustedInstaller — must take ownership first
        # before any write is possible, even as Administrator.
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $metKeyRel,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership
        )
        $acl = $regKey.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner([System.Security.Principal.NTAccount]'Administrators')
        $regKey.SetAccessControl($acl)
        $regKey.Close()

        # Now re-open with ChangePermissions and grant Administrators full control
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $metKeyRel,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions
        )
        $acl  = $regKey.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            [System.Security.Principal.NTAccount]'Administrators',
            'FullControl',
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.SetAccessRule($rule)
        $regKey.SetAccessControl($acl)
        $regKey.Close()

        # Safe to write now — only print [OK] if the write actually succeeds
        $existing = (Get-ItemProperty $metKeyPS -ErrorAction SilentlyContinue).Ethernet
        if ($existing -eq 2) {
            Write-OK "Ethernet already marked as metered"
        } else {
            if ($PSCmdlet.ShouldProcess($metKeyPS, "Set Ethernet cost=2 (metered)")) {
                Set-ItemProperty -Path $metKeyPS -Name 'Ethernet' -Value 2 -Type DWord -Force -ErrorAction Stop
                Write-OK "Ethernet marked as metered (cost=2)"
            }
        }
    } catch {
        Write-Warn "Could not mark Ethernet as metered: $_"
        Write-Info "  Set manually: Settings > Network > adapter > Properties > Metered connection"
    }
} else {
    Write-Info "Skipping metered connection (-SkipMetered specified)"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Head "Done"
Write-Info "Updates paused until : $($expiry.ToString('yyyy-MM-dd'))"
Write-Info "Services (Manual)    : wuauserv, UsoSvc, WaaSMedicSvc"
Write-Info "GP keys applied      : NoAutoUpdate, NoAutoRebootWithLoggedOnUsers, AUOptions=1"
Write-Info "DO peer downloads    : disabled (HTTP only)"
Write-Info "Version lock         : enabled (current feature version)"
Write-Info ""
Write-Warn "REMINDER — when you WANT to update deliberately:"
Write-Info "  1. .\CN-DisableWindowsUpdates.ps1 -Undo"
Write-Info "  2. Run Windows Update, install all, reboot"
Write-Info "  3. .\CN-DisableWindowsUpdates.ps1   (re-lock)"
Write-Info ""
Write-OK "CN Hub update lock applied."
