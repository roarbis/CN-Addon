#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Connect Nest — ConnectHub PC Preparation Script

.DESCRIPTION
    Prepares a customer's Windows PC the day before an on-site visit.
    Run remotely via RustDesk/TeamViewer on the customer's machine.

    What it does (in order):
      1. Checks prerequisites (OS, admin rights, internet)
      2. Sets Windows Power Plan to Best Performance
      3. Disables Power Throttling for VirtualBox processes
      4. Installs VirtualBox silently
      5. Downloads the latest Home Assistant OS VDI image
      6. Creates the ConnectHub VirtualBox VM (auto-detects best network adapter)
      7. Starts the VM headless (HA begins downloading on first boot)
      8. Installs RustDesk silently
      9. Sets RustDesk permanent password and installs as service
     10. Prints and saves summary (RustDesk ID + password)
     11. Emails summary to hello@connectnest.com.au via GAS (if -GASEndpoint provided)

.NOTES
    Author:  Connect Nest (product: ConnectHub)
    Version: 1.0
    Date:    2026-04-06

    Run as Administrator from PowerShell:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\CN-PrepCustomerPC.ps1

    Optional parameters:
        -RustDeskPassword  "YourPassword"                    # auto-generated if omitted
        -CustomerName      "Smith Family"                    # used in email subject line
        -GASEndpoint       "https://script.google.com/..."  # GAS web app URL (from team password manager)
        -VMRamMB           8192                              # default 4096
        -VMCpus            4                                 # default 2
        -HAOSDestFolder    "C:\CN-Setup"                     # default C:\CN-Setup
        -SkipVM                                              # skip VM creation
        -SkipRustDesk                                        # skip RustDesk install
#>

param(
    [string] $RustDeskPassword  = "",
    [string] $CustomerName      = "",          # Optional: customer name for email subject
    [string] $GASEndpoint       = "",          # Optional: GAS web app URL (from team password manager)
    [int]    $VMRamMB           = 4096,
    [int]    $VMCpus            = 2,
    [string] $HAOSDestFolder    = "C:\CN-Setup",
    [switch] $SkipVM,
    [switch] $SkipRustDesk
)

# ─────────────────────────────────────────────────────────────────────────────
# Colours + logging
# ─────────────────────────────────────────────────────────────────────────────
$ESC  = [char]27
function Write-Step  ($n, $total, $msg) { Write-Host "${ESC}[96m`n[$n/$total] $msg${ESC}[0m" }
function Write-OK    ($msg)             { Write-Host "${ESC}[92m  ✓ $msg${ESC}[0m" }
function Write-Warn  ($msg)             { Write-Host "${ESC}[93m  ⚠ $msg${ESC}[0m" }
function Write-Fail  ($msg)             { Write-Host "${ESC}[91m  ✗ $msg${ESC}[0m" }
function Write-Info  ($msg)             { Write-Host "${ESC}[37m    $msg${ESC}[0m" }
function Write-Banner($msg)             {
    $line = "=" * 60
    Write-Host "${ESC}[96m`n$line`n  $msg`n$line${ESC}[0m"
}

$TotalSteps    = 11
$ScriptVersion = "2.0"   # increment each time fixes are applied

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0 — Header
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Banner "Connect Nest — ConnectHub PC Preparation Script v$ScriptVersion"
Write-Info "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Info "Machine: $env:COMPUTERNAME  |  User: $env:USERNAME"
Write-Info ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 1 $TotalSteps "Checking prerequisites"

# Windows version
$os = Get-CimInstance Win32_OperatingSystem
Write-Info "OS: $($os.Caption) Build $($os.BuildNumber)"
if ([int]$os.BuildNumber -lt 17763) {
    Write-Fail "Windows 10 1809 (Build 17763) or newer required. Aborting."
    exit 1
}
Write-OK "Windows version OK"

# Admin check (already enforced by #Requires but double-check)
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Script must be run as Administrator. Right-click PowerShell → Run as Administrator."
    exit 1
}
Write-OK "Running as Administrator"

# Internet connectivity
try {
    $null = Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-OK "Internet connectivity confirmed"
} catch {
    Write-Fail "No internet access. This script requires internet. Aborting."
    exit 1
}

# Create working folder
if (-not (Test-Path $HAOSDestFolder)) {
    New-Item -ItemType Directory -Path $HAOSDestFolder -Force | Out-Null
}
Write-OK "Working folder: $HAOSDestFolder"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Windows Power Plan: Best Performance
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 2 $TotalSteps "Setting Windows Power Plan to Best Performance"

# GUID for Ultimate Performance (Windows 10/11 hidden plan)
$ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"

# Try to enable Ultimate Performance plan (hidden by default)
$dupResult = powercfg /duplicatescheme $ultimateGuid 2>&1
if ($LASTEXITCODE -eq 0 -or $dupResult -match $ultimateGuid) {
    powercfg /setactive $ultimateGuid | Out-Null
    Write-OK "Ultimate Performance power plan activated"
} else {
    # Fallback to High Performance
    $highPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    powercfg /setactive $highPerfGuid | Out-Null
    Write-OK "High Performance power plan activated (Ultimate not available on this edition)"
}

# Disable sleep and hibernation
powercfg /change standby-timeout-ac 0    | Out-Null
powercfg /change hibernate-timeout-ac 0  | Out-Null
powercfg /change monitor-timeout-ac 0    | Out-Null
powercfg /hibernate off                  | Out-Null
Write-OK "Sleep and hibernate disabled (AC power)"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2b — Host Performance Tuning (dedicated single-purpose VM host)
# ─────────────────────────────────────────────────────────────────────────────
Write-Info ""
Write-Info "Applying host performance tuning (dedicated VM host)..."

# Processor scheduling → Background Services
# Win32PrioritySeparation 24 = short quantum intervals, no foreground boost.
# VBoxHeadless is a background process — the default "Programs" mode actively
# starves it whenever any foreground window (e.g. RustDesk session) is active.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' `
    -Name 'Win32PrioritySeparation' -Value 24 -Type DWord -Force
Write-OK "Processor scheduling → Background Services (VM gets equal CPU priority)"

# Visual effects → Best Performance (same as sysdm.cpl → Advanced → Visual Effects)
$null = New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
        -Force -ErrorAction SilentlyContinue
Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
    -Name 'VisualFXSetting' -Value 2 -Type DWord -Force
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name 'DragFullWindows' -Value '0' -Force
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay'   -Value '0' -Force
Write-OK "Visual effects → Best Performance (animations + compositor overhead disabled)"

# Windows Defender exclusions for VM disk I/O — largest single source of VM latency.
# Defender scanning VDI disk writes in real-time can halve effective I/O bandwidth.
try {
    Add-MpPreference -ExclusionPath      $HAOSDestFolder                                          -ErrorAction Stop
    Add-MpPreference -ExclusionExtension '.vdi','.vmdk','.vbox'                                   -ErrorAction Stop
    Add-MpPreference -ExclusionProcess   'VBoxHeadless.exe','VBoxSVC.exe','VBoxManage.exe'        -ErrorAction Stop
    Write-OK "Defender exclusions added: VM folder + VDI/VMDK extensions + VirtualBox processes"
} catch {
    Write-Warn "Could not add Defender exclusions (non-fatal): $_"
}

# Disable Fast Startup / Hybrid Boot
# Fast Startup saves a kernel hibernation snapshot on shutdown — VirtualBox drivers
# are not re-initialised on next boot, which can cause COM registration failures.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
    -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
Write-OK "Fast Startup (Hybrid Boot) disabled — clean driver reload on every boot"

# Disable services that waste resources on a headless VM host.
# Spooler and Fax are excluded from this list — they are needed for some monitoring
# agents and leaving them running has negligible cost vs. risk of breakage.
$svcsToDisable = @(
    'SysMain',          # Superfetch/Prefetch — wastes RAM prefetching apps never run here
    'WSearch',          # Windows Search — continuous disk I/O indexing files never searched
    'DiagTrack',        # Connected User Experiences & Telemetry — background network + I/O
    'XblAuthManager',   # Xbox Live Auth
    'XblGameSave',      # Xbox Game Save
    'XboxNetApiSvc',    # Xbox Network
    'RetailDemo'        # Retail demo mode service
)
foreach ($svcName in $svcsToDisable) {
    $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $svcName -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Service  $svcName -StartupType Disabled -ErrorAction SilentlyContinue
        Write-OK "Service disabled: $svcName ($($s.DisplayName))"
    }
}

# Disable GameDVR / Xbox Game Bar
# Hooks into every process at startup and adds measurable scheduling latency.
$null = New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Force -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
    -Name 'AllowGameDVR' -Value 0 -Type DWord -Force
Write-OK "GameDVR / Xbox Game Bar disabled"

# Set current user's password to never expire
# CNAdmin is the sole operator account — a forced expiry would lock out the
# scheduled task (S4U) and remote access without anyone on-site to fix it.
$adminUser = Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue
if ($adminUser) {
    Set-LocalUser -Name $env:USERNAME -PasswordNeverExpires $true -ErrorAction SilentlyContinue
    $check = (Get-LocalUser -Name $env:USERNAME).PasswordNeverExpires
    if ($check) {
        Write-OK "Password set to never expire for user: $env:USERNAME"
    } else {
        Write-Warn "Could not confirm PasswordNeverExpires for '$env:USERNAME' — check manually in lusrmgr.msc"
    }
} else {
    Write-Warn "Local user '$env:USERNAME' not found — skipping password expiry setting"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Power Throttling: Disable for VirtualBox processes
# (Runs now so the policy is set before VirtualBox is installed.
#  Will be re-applied after install for belt-and-suspenders.)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 3 $TotalSteps "Configuring Power Throttling exceptions"

$vboxPaths = @(
    "C:\Program Files\Oracle\VirtualBox\VBoxHeadless.exe",
    "C:\Program Files\Oracle\VirtualBox\VirtualBoxVM.exe",
    "C:\Program Files\Oracle\VirtualBox\VBoxSVC.exe"
)

foreach ($path in $vboxPaths) {
    $result = powercfg /powerthrottling disable /path $path 2>&1
    Write-Info "Power throttling disabled (pre-emptive): $([System.IO.Path]::GetFileName($path))"
}

# List current overrides
Write-Info "Current power throttling overrides:"
powercfg /powerthrottling list 2>&1 | ForEach-Object { Write-Info "  $_" }
Write-OK "Power throttling exceptions registered"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Install VirtualBox
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 4 $TotalSteps "Installing VirtualBox"

$vboxExe = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

if (Test-Path $vboxExe) {
    $vboxVer = & $vboxExe --version 2>&1
    Write-OK "VirtualBox already installed: $vboxVer — skipping"
} else {
    # Always use the official .exe installer downloaded directly from VirtualBox.
    # winget --silent was dropped because it leaves COM (VBoxC.dll) unregistered.
    # We resolve the exact filename dynamically from the CDN directory listing so
    # we never need to hardcode a build number (e.g. 7.2.6r172322 → r172322 part).
    Write-Info "Fetching latest VirtualBox release version..."
    $vboxUrl       = $null
    $vboxInstaller = $null
    $vboxVersion   = $null
    try {
        $cdnBase    = "https://download.virtualbox.org/virtualbox"
        $vboxVersion = (Invoke-WebRequest "$cdnBase/LATEST-STABLE.TXT" `
                            -UseBasicParsing -TimeoutSec 10).Content.Trim()
        Write-Info "Latest stable release from VirtualBox CDN: $vboxVersion"

        # Parse the CDN directory listing for that version to get the exact filename.
        # This avoids hardcoding build numbers (the rNNNNNN suffix changes each release).
        $dirHtml = (Invoke-WebRequest "$cdnBase/$vboxVersion/" `
                        -UseBasicParsing -TimeoutSec 15).Content
        $winExe  = [regex]::Match($dirHtml, "VirtualBox-$([regex]::Escape($vboxVersion))-\d+-Win\.exe").Value
        if (-not $winExe) { throw "Could not find Win installer filename in CDN directory for $vboxVersion" }

        $vboxUrl       = "$cdnBase/$vboxVersion/$winExe"
        $vboxInstaller = "$HAOSDestFolder\$winExe"
        Write-Info "Installer : $winExe"
        Write-Info "URL       : $vboxUrl"
    } catch {
        Write-Fail "Could not resolve VirtualBox download URL: $_"
        Write-Warn "Manual download: https://www.virtualbox.org/wiki/Downloads"
        Write-Warn "Place VirtualBox-<ver>-Win.exe in $HAOSDestFolder and re-run."
    }

    if ($vboxUrl -and $vboxInstaller) {
        Write-Info "Downloading VirtualBox $vboxVersion from virtualbox.org..."
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($vboxUrl, $vboxInstaller)
            Write-OK "Download complete: $vboxInstaller"
        } catch {
            Write-Fail "Download failed: $_"
            Write-Warn "Manual download: https://www.virtualbox.org/wiki/Downloads"
            $vboxInstaller = $null
        }
    }

    if ($vboxInstaller -and (Test-Path $vboxInstaller)) {
        Write-Info "Running VirtualBox installer (this takes ~2 minutes)..."
        # --silent + REBOOT=ReallySuppress: quiet install, no reboot prompt
        # Does NOT suppress COM registration — that's the key advantage over winget
        $vbProc = Start-Process -FilePath $vboxInstaller `
                                -ArgumentList "--silent", "--msiparams", "REBOOT=ReallySuppress" `
                                -PassThru -Wait
        if ($vbProc.ExitCode -eq 0 -or $vbProc.ExitCode -eq 3010) {
            Write-OK "VirtualBox $vboxVersion installed (exit $($vbProc.ExitCode))"
            # Exit 3010 = success but reboot required — we suppress it; harmless here
        } else {
            Write-Fail "VirtualBox installer exited with code $($vbProc.ExitCode)"
            Write-Warn "Run installer manually from $vboxInstaller to see error dialog."
        }
        Remove-Item $vboxInstaller -Force -ErrorAction SilentlyContinue
    }

    # Refresh PATH so VBoxManage is accessible in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")

    if (-not (Test-Path $vboxExe)) {
        Write-Fail "VBoxManage.exe not found after install. Check C:\Program Files\Oracle\VirtualBox\"
        Write-Warn "Continuing — VM creation will be skipped if VBoxManage unavailable."
    } else {
        Write-OK "VBoxManage confirmed at: $vboxExe"

        # Re-apply power throttling now that paths exist
        foreach ($path in $vboxPaths) {
            powercfg /powerthrottling disable /path $path 2>&1 | Out-Null
        }
        Write-OK "Power throttling exceptions re-applied post-install"
    }
}

# Re-register VirtualBox COM objects (VBoxC.dll) every run.
# Silent and winget installs sometimes leave COM CLSID entries corrupt or
# missing — especially after repeated install/uninstall cycles. regsvr32
# re-writes all CLSID → LocalServer32 entries in HKLM so both elevated
# and non-elevated processes can reach VBoxSVC via COM.
$vboxCom = "C:\Program Files\Oracle\VirtualBox\VBoxC.dll"
if (Test-Path $vboxCom) {
    Write-Info "Re-registering VirtualBox COM objects (VBoxC.dll)..."
    $regOut = & regsvr32 /s $vboxCom 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "VBoxC.dll COM registration refreshed"
    } else {
        Write-Warn "regsvr32 returned exit $LASTEXITCODE — COM may still be usable, continuing"
    }
}

# Ensure VirtualBox shortcuts exist regardless of install path.
# Silent / winget installs sometimes skip shortcut creation.
# Windows 11 removed programmatic taskbar pinning — right-click the desktop
# shortcut and choose "Pin to taskbar" manually after first run.
$vboxGuiExe = "C:\Program Files\Oracle\VirtualBox\VirtualBox.exe"
if (Test-Path $vboxGuiExe) {
    $wsh = New-Object -ComObject WScript.Shell

    # Start Menu — global (all users)
    $smFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Oracle VM VirtualBox"
    if (-not (Test-Path $smFolder)) { New-Item -ItemType Directory $smFolder -Force | Out-Null }
    $smLnk = "$smFolder\VirtualBox.lnk"
    if (-not (Test-Path $smLnk)) {
        $lnk = $wsh.CreateShortcut($smLnk)
        $lnk.TargetPath       = $vboxGuiExe
        $lnk.WorkingDirectory = Split-Path $vboxGuiExe
        $lnk.Description      = "VirtualBox Manager"
        $lnk.Save()
        Write-OK "VirtualBox shortcut → Start Menu (all users)"
    } else {
        Write-OK "VirtualBox Start Menu shortcut already present"
    }

    # Desktop — common desktop (all users see it)
    $desktopLnk = "$env:PUBLIC\Desktop\VirtualBox.lnk"
    if (-not (Test-Path $desktopLnk)) {
        $lnk = $wsh.CreateShortcut($desktopLnk)
        $lnk.TargetPath       = $vboxGuiExe
        $lnk.WorkingDirectory = Split-Path $vboxGuiExe
        $lnk.Description      = "VirtualBox Manager"
        $lnk.IconLocation     = "$vboxGuiExe,0"
        $lnk.Save()
        Write-OK "VirtualBox shortcut → Desktop (all users)"
    } else {
        Write-OK "VirtualBox Desktop shortcut already present"
    }
    Write-Info "(To add to Taskbar: right-click the Desktop shortcut → 'Pin to taskbar')"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Download Home Assistant OS VDI
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 5 $TotalSteps "Downloading Home Assistant OS (HAOS) VDI image"

$haosVdi = "$HAOSDestFolder\haos_ova.vdi"

if (Test-Path $haosVdi) {
    $existingSize = (Get-Item $haosVdi).Length / 1MB
    Write-OK "HAOS VDI already exists ($([math]::Round($existingSize,0)) MB) — skipping download"
} else {
    Write-Info "Fetching latest HAOS release version from GitHub..."
    try {
        $releaseInfo = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/home-assistant/operating-system/releases/latest" `
            -Headers @{ "User-Agent" = "ConnectHub-PrepScript/1.0" }
        $haosVersion = $releaseInfo.tag_name   # e.g. "13.1"
        Write-Info "Latest HAOS version: $haosVersion"

        # Find the VDI asset (VirtualBox native format)
        $vdiAsset = $releaseInfo.assets | Where-Object { $_.name -match "haos_ova-.*\.vdi\.zip$" } |
                    Select-Object -First 1
        if (-not $vdiAsset) {
            # Fallback: try VMDK (also works with VirtualBox)
            $vdiAsset = $releaseInfo.assets | Where-Object { $_.name -match "haos_ova-.*\.vmdk\.zip$" } |
                        Select-Object -First 1
        }
        if (-not $vdiAsset) {
            throw "No VDI or VMDK asset found in latest HAOS release."
        }

        $downloadUrl  = $vdiAsset.browser_download_url
        $archiveName  = $vdiAsset.name
        $archivePath  = "$HAOSDestFolder\$archiveName"
        $downloadSize = [math]::Round($vdiAsset.size / 1MB, 0)
        Write-Info "Asset: $archiveName ($downloadSize MB)"
        Write-Info "URL:   $downloadUrl"
        Write-Info "Downloading... (this may take several minutes on slow connections)"

        # Download with progress
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($downloadUrl, $archivePath)
        Write-OK "Download complete: $archivePath"

        # Extract ZIP
        Write-Info "Extracting archive..."
        Expand-Archive -Path $archivePath -DestinationPath $HAOSDestFolder -Force

        # Find extracted VDI/VMDK file
        # Note: -Filter only accepts a single string; use Where-Object for multi-extension matching
        $extractedDisk = Get-ChildItem -Path $HAOSDestFolder -Recurse |
                         Where-Object { $_.Extension -in '.vdi','.vmdk' -and $_.Name -notmatch 'VirtualBox' } |
                         Select-Object -First 1
        if ($extractedDisk) {
            Move-Item $extractedDisk.FullName $haosVdi -Force
            Write-OK "HAOS disk image saved to: $haosVdi"
        } else {
            Write-Fail "Could not locate extracted disk image. Check $HAOSDestFolder manually."
        }

        # Clean up zip
        Remove-Item $archivePath -Force -ErrorAction SilentlyContinue
        Write-OK "Archive cleaned up"

    } catch {
        Write-Fail "Failed to download HAOS: $_"
        Write-Warn "Manual download: https://www.home-assistant.io/installation/generic-x86-64"
        Write-Warn "Download the VirtualBox (.vdi) image and place it at: $haosVdi"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Create VirtualBox VM
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 6 $TotalSteps "Creating ConnectHub VirtualBox VM"

$VMName = "ConnectHub"

if ($SkipVM) {
    Write-Warn "SkipVM flag set — skipping VM creation"
} elseif (-not (Test-Path $vboxExe)) {
    Write-Warn "VBoxManage not found — skipping VM creation"
} elseif (-not (Test-Path $haosVdi)) {
    Write-Warn "HAOS VDI not found at $haosVdi — skipping VM creation"
} else {
    # Start VBoxSVC in the SAME elevated context as this script.
    #
    # Why we always kill+restart (not just "start if missing"):
    # Windows COM uses session isolation. An elevated process (this script)
    # cannot connect to a COM server that was started non-elevated — e.g. by
    # winget's post-install step or by a user double-clicking VirtualBox.exe.
    # The symptom: REGDB_E_CLASSNOTREG from VBoxManage even though VBoxSVC
    # appears running in Task Manager and the registry key exists.
    # Restarting VBoxSVC from THIS elevated session fixes the mismatch.
    # Safe here because no VMs should be running during D-1 provisioning.
    $vboxSvc = Join-Path (Split-Path $vboxExe) "VBoxSVC.exe"
    $svcProc = Get-Process "VBoxSVC" -ErrorAction SilentlyContinue
    if ($svcProc) {
        Write-Info "Stopping VBoxSVC (PID $($svcProc.Id)) — restarting in elevated context..."
        Stop-Process $svcProc -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if (Test-Path $vboxSvc) {
        Write-Info "Starting VBoxSVC in elevated context..."
        Start-Process $vboxSvc -ArgumentList "--auto-shutdown" -WindowStyle Hidden
    }

    Write-Info "Waiting for VBoxSVC COM registration (up to 60s)..."
    $existingVMs = $null
    $vboxReady   = $false
    for ($vboxWait = 1; $vboxWait -le 12; $vboxWait++) {
        Start-Sleep -Seconds 5
        $probe = & $vboxExe list vms 2>&1
        if ($LASTEXITCODE -eq 0) {
            $existingVMs = $probe
            $vboxReady   = $true
            Write-OK "VBoxSVC ready (took ~$($vboxWait * 5)s)"
            break
        }
        Write-Info "  Not ready yet — attempt $vboxWait/12 ($($vboxWait * 5)s elapsed)..."
    }
    if (-not $vboxReady) {
        Write-Fail "VBoxSVC COM did not respond after 60s."
        Write-Warn "Likely cause: VirtualBox not installed cleanly (Hyper-V conflict?)."
        Write-Warn "Fix: reboot and re-run. If it persists, reinstall VirtualBox."
    }

    if ($vboxReady -and ($existingVMs -match "`"$VMName`"")) {
        Write-OK "VM '$VMName' already exists — skipping creation"
    } elseif ($vboxReady) {
        # Auto-detect the best network adapter for Bridged Networking
        # Priority: active Ethernet > active Wi-Fi > first available
        Write-Info "Auto-detecting best network adapter for Bridged Networking..."

        $adapters = & $vboxExe list bridgedifs 2>&1 | Select-String "^Name:" | ForEach-Object {
            ($_ -replace "^Name:\s+","").Trim()
        }
        Write-Info "Available adapters: $($adapters -join ', ')"

        # Query Windows for physical adapters with link-up status
        $netAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                       Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } |
                       Sort-Object -Property @{Expression={
                           # Ethernet gets highest priority
                           if ($_.MediaType -eq '802.3') { 0 }
                           elseif ($_.Name -match 'Ethernet|LAN') { 1 }
                           else { 2 }
                       }}

        $chosenAdapter = $null

        # Try to match a connected Windows adapter to a VBoxManage adapter name
        foreach ($na in $netAdapters) {
            $match = $adapters | Where-Object {
                $_ -like "*$($na.Name)*" -or $na.Name -like "*$($_)*" -or
                $_ -like "*$($na.InterfaceDescription)*"
            } | Select-Object -First 1
            if ($match) {
                $chosenAdapter = $match
                Write-OK "Auto-selected adapter (active, $($na.MediaType)): $chosenAdapter"
                break
            }
        }

        # Fallback: prefer any adapter containing "Ethernet" in its name
        if (-not $chosenAdapter) {
            $chosenAdapter = $adapters | Where-Object { $_ -match 'Ethernet|LAN' } |
                             Select-Object -First 1
        }
        # Last resort: first adapter in the list
        if (-not $chosenAdapter) {
            $chosenAdapter = $adapters | Select-Object -First 1
        }
        if (-not $chosenAdapter) {
            $chosenAdapter = "Ethernet"
            Write-Warn "No adapters detected — defaulting to 'Ethernet'. You can change this in VirtualBox Manager."
        }

        Write-Info "Selected adapter: $chosenAdapter"
        Write-Info "(To change: VirtualBox Manager → ConnectHub → Settings → Network → Adapter 1)"
        Write-Info ""

        # Create VM
        Write-Info "Creating VM '$VMName'..."
        $createOut = & $vboxExe createvm --name $VMName --ostype "Linux_64" --register 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "createvm failed: $createOut"
            Write-Warn "Cannot configure VM — check VirtualBox installation and re-run."
        } else {

        # Configure resources
        & $vboxExe modifyvm $VMName `
            --memory $VMRamMB `
            --cpus $VMCpus `
            --vram 16 `
            --graphicscontroller vmsvga `
            --firmware efi `
            --nic1 bridged `
            --bridgeadapter1 $chosenAdapter `
            --natdnshostresolver1 off `
            --audio none `
            --usb off `
            --usbehci off `
            --usbxhci off | Out-Null
        Write-OK "VM resources: $VMRamMB MB RAM, $VMCpus CPUs, Bridged: $chosenAdapter"

        # Add storage controller
        & $vboxExe storagectl $VMName --name "SATA" --add sata --controller IntelAhci | Out-Null

        # Attach HAOS disk
        & $vboxExe storageattach $VMName `
            --storagectl "SATA" `
            --port 0 `
            --device 0 `
            --type hdd `
            --medium $haosVdi | Out-Null
        Write-OK "HAOS VDI attached as boot disk"

        # Configure boot order
        & $vboxExe modifyvm $VMName --boot1 disk --boot2 none --boot3 none --boot4 none | Out-Null

        Write-OK "VM '$VMName' created successfully"
        }  # end if ($createOut succeeded)
    }      # end elseif ($vboxReady) — VM creation block

    # Check VM state before attempting start — avoid "already locked" error
    $vmState = & $vboxExe showvminfo $VMName --machinereadable 2>&1 |
               Select-String 'VMState=' |
               ForEach-Object { ($_ -replace 'VMState=|"','').Trim() }

    if ($vmState -eq 'running') {
        Write-OK "VM '$VMName' is already running — skipping start"
    } else {
        Write-Info "VM state: '$vmState' — starting headless..."
        $vmStarted = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $startOut = & $vboxExe startvm $VMName --type headless 2>&1
            if ($LASTEXITCODE -eq 0) { $vmStarted = $true; break }
            Write-Info "Start attempt $attempt failed — waiting 5s before retry..."
            Start-Sleep -Seconds 5
        }
        if ($vmStarted) {
            Write-OK "VM '$VMName' started headless"
        } else {
            Write-Warn "VM failed to start after 3 attempts: $startOut"
            Write-Warn "Open VirtualBox Manager and start 'ConnectHub' manually, then re-run with -SkipVM."
        }
    }
    Write-Info "HA URL: http://{router-DHCP-IP}:8123 (check router for hostname 'homeassistant')"

    # Register scheduled task so VM auto-starts on Windows boot.
    # IMPORTANT: Must run as the current user (CNAdmin), NOT SYSTEM.
    # VirtualBox VMs are registered per-user — SYSTEM has no VM registry and
    # startvm silently finds nothing. S4U logon = runs as the specified user
    # account without a stored password, even when no one is logged in.
    Write-Info "Registering VM auto-start scheduled task..."
    $taskName  = "CN-StartHAOS"
    $taskUser  = "$env:USERDOMAIN\$env:USERNAME"

    $action    = New-ScheduledTaskAction `
                     -Execute  $vboxExe `
                     -Argument "startvm `"$VMName`" --type headless"

    # 1-minute startup delay: gives VirtualBox COM server (VBoxSVC) time to
    # initialise before VBoxManage tries to use it.
    $trigger         = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay   = 'PT1M'   # ISO 8601: 1 minute

    $settings  = New-ScheduledTaskSettingsSet `
                     -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                     -RestartCount       3 `
                     -RestartInterval    (New-TimeSpan -Minutes 1) `
                     -StartWhenAvailable             # switch — fires even after hard power-cycle

    $principal = New-ScheduledTaskPrincipal `
                     -UserId    $taskUser `
                     -LogonType S4U `
                     -RunLevel  Highest

    Register-ScheduledTask `
        -TaskName  $taskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force | Out-Null
    Write-OK "Scheduled task '$taskName' created — VM will auto-start on every Windows boot"
    Write-OK "  Runs as: $taskUser (S4U — no stored password, works without logon)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Install RustDesk
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 7 $TotalSteps "Installing RustDesk"

$rustdeskExe = "C:\Program Files\RustDesk\rustdesk.exe"

if ($SkipRustDesk) {
    Write-Warn "SkipRustDesk flag set — skipping"
} elseif (Test-Path $rustdeskExe) {
    Write-OK "RustDesk already installed — skipping install"
} else {
    Write-Info "Fetching latest RustDesk release from GitHub..."
    try {
        $rdRelease = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" `
            -Headers @{ "User-Agent" = "ConnectHub-PrepScript/1.0" }

        # Find Windows x86-64 installer (.exe, not .msi, not sciter)
        $rdAsset = $rdRelease.assets | Where-Object {
            $_.name -match "rustdesk.*x86_64.*\.exe$" -and $_.name -notmatch "sciter"
        } | Select-Object -First 1

        if (-not $rdAsset) {
            # Try MSI fallback
            $rdAsset = $rdRelease.assets | Where-Object {
                $_.name -match "rustdesk.*x86_64.*\.msi$"
            } | Select-Object -First 1
        }

        if (-not $rdAsset) {
            throw "Could not find RustDesk Windows installer in latest release"
        }

        $rdUrl      = $rdAsset.browser_download_url
        $rdVersion  = $rdRelease.tag_name
        $rdInstaller= "$HAOSDestFolder\rustdesk-installer$([System.IO.Path]::GetExtension($rdAsset.name))"

        Write-Info "Downloading RustDesk $rdVersion ($($rdAsset.name))..."
        $webClient2 = New-Object System.Net.WebClient
        $webClient2.DownloadFile($rdUrl, $rdInstaller)
        Write-OK "Download complete"

        Write-Info "Installing RustDesk silently (up to 3 minutes)..."
        if ($rdInstaller -match "\.msi$") {
            $rdProc = Start-Process msiexec `
                          -ArgumentList "/i `"$rdInstaller`" /quiet /norestart" `
                          -PassThru -WindowStyle Hidden
        } else {
            $rdProc = Start-Process $rdInstaller -ArgumentList "--silent-install" `
                          -PassThru -WindowStyle Hidden
        }
        $rdDone = $rdProc.WaitForExit(180000)   # 3-minute hard timeout
        if (-not $rdDone) {
            $rdProc.Kill()
            Write-Warn "RustDesk installer exceeded 3 minutes — killed. May still have installed."
        }

        Remove-Item $rdInstaller -Force -ErrorAction SilentlyContinue

        # Tauri-based installers can spawn a child process — wait up to 30s for rustdesk.exe
        Write-Info "Waiting for RustDesk installation to finalise..."
        $rdWait = 0
        while (-not (Test-Path $rustdeskExe) -and $rdWait -lt 30) {
            Start-Sleep -Seconds 3; $rdWait += 3
        }
        if (Test-Path $rustdeskExe) {
            Write-OK "RustDesk installed at $rustdeskExe"
        } else {
            Write-Warn "RustDesk .exe not found at expected path — check C:\Program Files\RustDesk\"
        }
    } catch {
        Write-Fail "RustDesk download/install failed: $_"
        Write-Warn "Manual: https://github.com/rustdesk/rustdesk/releases/latest"
    }
}

# Add Windows Firewall rules for RustDesk so the "allow network access?" popup
# never appears during or after install. Rules are idempotent (-ErrorAction SilentlyContinue
# silently skips if a rule with that name already exists).
if (Test-Path $rustdeskExe) {
    Write-Info "Adding Windows Firewall rules for RustDesk..."
    # Allow the executable (covers all ports RustDesk may use)
    New-NetFirewallRule -DisplayName "RustDesk (In)"  -Direction Inbound  `
        -Program $rustdeskExe -Action Allow -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "RustDesk (Out)" -Direction Outbound `
        -Program $rustdeskExe -Action Allow -Profile Any `
        -ErrorAction SilentlyContinue | Out-Null
    # Explicit port rules as belt-and-braces (relay + direct connection ports)
    New-NetFirewallRule -DisplayName "RustDesk TCP ports" -Direction Inbound `
        -Protocol TCP -LocalPort 21115,21116,21117,21118,21119 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "RustDesk UDP port" -Direction Inbound `
        -Protocol UDP -LocalPort 21116 `
        -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
    Write-OK "Firewall rules added for RustDesk (no popup on connect)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Configure RustDesk: permanent password + install as service
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 8 $TotalSteps "Configuring RustDesk (service + permanent password)"

if ($SkipRustDesk) {
    Write-Warn "SkipRustDesk flag set — skipping"
} elseif (-not (Test-Path $rustdeskExe)) {
    Write-Warn "RustDesk not found — skipping configuration"
} else {
    # Generate password if not provided
    if (-not $RustDeskPassword) {
        # 16-char alphanumeric — memorable but strong
        $chars = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
        $RustDeskPassword = -join ((0..15) | ForEach-Object { $chars[(Get-Random -Max $chars.Length)] })
        Write-Info "Auto-generated RustDesk password: $RustDeskPassword"
    }

    # Helper: run RustDesk CLI with a hard timeout so it can never hang the script.
    # NOTE: $Args is a reserved PS automatic variable — NEVER use it as a param name.
    function Invoke-RustDesk {
        param([string[]]$RdArgs, [int]$TimeoutSec = 15)
        $proc = Start-Process -FilePath $rustdeskExe `
                              -ArgumentList $RdArgs `
                              -WindowStyle Hidden `
                              -PassThru `
                              -RedirectStandardOutput "$env:TEMP\rd_out.txt" `
                              -RedirectStandardError  "$env:TEMP\rd_err.txt"
        $finished = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $finished) {
            $proc.Kill()
            Write-Warn "RustDesk '$($RdArgs -join ' ')' timed out after ${TimeoutSec}s — killed"
        }
        $out = if (Test-Path "$env:TEMP\rd_out.txt") { Get-Content "$env:TEMP\rd_out.txt" -Raw } else { "" }
        return $out
    }

    # Set permanent password
    Write-Info "Setting permanent password..."
    Invoke-RustDesk -RdArgs "--password", $RustDeskPassword | Out-Null
    Write-OK "Permanent password set"

    # Install RustDesk as a Windows service (runs at boot, before user login)
    Write-Info "Installing RustDesk as Windows service..."
    Invoke-RustDesk -RdArgs "--install-service" | Out-Null
    Start-Sleep -Seconds 5

    # RustDesk service name varies by version — search by name and display name
    $rdService = Get-Service -Name "RustDesk" -ErrorAction SilentlyContinue
    if (-not $rdService) {
        $rdService = Get-Service -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "*rustdesk*" -or $_.DisplayName -like "*RustDesk*" } |
                     Select-Object -First 1
    }

    if ($rdService) {
        if ($rdService.Status -ne "Running") {
            Start-Service -Name $rdService.Name -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $rdService.Refresh()
        }
        Write-OK "RustDesk service '$($rdService.Name)': $($rdService.Status)"
        Set-Service -Name $rdService.Name -StartupType Automatic -ErrorAction SilentlyContinue
        Write-OK "RustDesk service set to Automatic startup"
    } else {
        Write-Warn "RustDesk service not found — may still be registering. Check services.msc after script."
    }

    # Get RustDesk ID (may need a moment after service start)
    Start-Sleep -Seconds 5
    $script:rustdeskID = ""
    try {
        $idOutput = Invoke-RustDesk -RdArgs "--get-id"
        $script:rustdeskID = ($idOutput | Select-String -Pattern "\d{9,}" |
                              Select-Object -First 1).Matches.Value
    } catch {}

    if ($script:rustdeskID) {
        Write-OK "RustDesk ID retrieved: $($script:rustdeskID)"
    } else {
        Write-Warn "Could not retrieve RustDesk ID automatically."
        Write-Warn "Open RustDesk manually to find the ID on the main screen."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Re-apply power throttling (belt and suspenders, now paths exist)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 9 $TotalSteps "Finalising Power Throttling exceptions"

foreach ($path in $vboxPaths) {
    if (Test-Path $path) {
        powercfg /powerthrottling disable /path $path 2>&1 | Out-Null
        Write-OK "Throttling disabled: $([System.IO.Path]::GetFileName($path))"
    }
}

# Verify
$throttleList = powercfg /powerthrottling list 2>&1
Write-Info "Active power throttling overrides:"
$throttleList | ForEach-Object { Write-Info "  $_" }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 10 $TotalSteps "Complete — Summary"

$summaryFile = "$HAOSDestFolder\CN-Setup-Summary.txt"
$vmDhcpNote  = "Check router DHCP table (hostname: homeassistant) for current IP"

$summary = @"
============================================================
  CONNECT NEST — CONNECTHUB SETUP SUMMARY
  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Machine:   $env:COMPUTERNAME
============================================================

VIRTUALBOX VM
  VM Name:        ConnectHub
  RAM:            $VMRamMB MB
  CPUs:           $VMCpus
  HAOS Disk:      $haosVdi
  Status:         Started headless (HA downloading on first boot)
  HA URL:         http://{DHCP-IP}:8123  — replace {DHCP-IP} with actual IP
  IP Note:        $vmDhcpNote

RUSTDESK REMOTE ACCESS
  RustDesk ID:    $($script:rustdeskID)
  Password:       $RustDeskPassword
  *** COPY THESE DOWN — needed to connect remotely from your device ***

POWER SETTINGS
  Power Plan:     Best Performance (Ultimate or High Performance)
  Sleep/Hibernate: DISABLED
  Power Throttling: DISABLED for VBoxHeadless.exe, VirtualBoxVM.exe, VBoxSVC.exe

NEXT STEPS (from your own machine)
  1. Connect to this PC via RustDesk using ID + password above
  2. Check http://{DHCP-IP}:8123 — wait for HA Create Account page (~10-20 min)
  3. Note the DHCP IP in your Site Information sheet
  4. On-site: proceed from Phase 3 (HA Initial Setup) of the install guide
     or Phase 4 (CN Add-on Install) if HA onboarding was done remotely too

WORKING FOLDER
  $HAOSDestFolder
============================================================
"@

Write-Host $summary
$summary | Out-File -FilePath $summaryFile -Encoding UTF8
Write-OK "Summary saved to: $summaryFile"

Write-Banner "IMPORTANT — NOTE THESE DOWN NOW"
Write-Host ""
Write-Host "  RustDesk ID  : ${ESC}[93m$($script:rustdeskID)${ESC}[0m"
Write-Host "  RustDesk PWD : ${ESC}[93m$RustDeskPassword${ESC}[0m"
Write-Host ""
Write-Info "Connect to this machine via RustDesk to monitor HA download progress."
Write-Info "HA ready when http://{DHCP-IP}:8123 shows the Create Account page."
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11 — Email summary via Google Apps Script endpoint
# ─────────────────────────────────────────────────────────────────────────────
Write-Step 11 $TotalSteps "Emailing setup summary"

if (-not $GASEndpoint) {
    Write-Warn "No -GASEndpoint provided — skipping email."
    Write-Info "To enable: get the GAS URL from your team password manager and pass it as:"
    Write-Info "  -GASEndpoint 'https://script.google.com/macros/s/.../exec'"
} else {
    $dateStr     = Get-Date -Format 'yyyy-MM-dd'
    $customerStr = if ($CustomerName) { $CustomerName } else { "Unknown Customer" }
    $summaryContent = if (Test-Path $summaryFile) { Get-Content $summaryFile -Raw } else { $summary }

    $postBody = @{
        action       = "ps_summary"
        customer     = $customerStr
        machine      = $env:COMPUTERNAME
        rustdesk_id  = $script:rustdeskID
        rustdesk_pwd = $RustDeskPassword
        summary      = $summaryContent
    } | ConvertTo-Json -Compress

    try {
        Write-Info "Sending to GAS endpoint..."
        $response = Invoke-RestMethod `
            -Uri       $GASEndpoint `
            -Method    POST `
            -Body      $postBody `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -ErrorAction Stop

        if ($response.ok -eq $true) {
            Write-OK "Email sent successfully to hello@connectnest.com.au"
            Write-Info "Subject: [CN Hub Ready] $customerStr — $($env:COMPUTERNAME) — $dateStr"
        } else {
            Write-Warn "GAS responded but reported an error: $($response.error)"
        }
    } catch {
        Write-Warn "GAS request failed: $_"
        Write-Warn "Summary is still saved locally at: $summaryFile"
        Write-Warn "You can email it manually if needed."
    }
}






