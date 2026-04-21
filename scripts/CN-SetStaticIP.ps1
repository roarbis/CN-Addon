<#
.SYNOPSIS
  Locks the CN Hub Windows host to its current DHCP-assigned IP as a static IP.
  Run AT THE CUSTOMER SITE on D-Day, AFTER the NUC has fully booted on the
  customer router and Home Assistant has also booted.

.DESCRIPTION
  Reads the currently bound IPv4 address, gateway, subnet prefix, and DNS servers
  from the primary physical network adapter, then:
    1. Disables DHCP on that adapter.
    2. Re-applies the SAME address/prefix/gateway as a static configuration.
    3. Re-applies the SAME DNS servers (or falls back to 1.1.1.1 / 8.8.8.8).
    4. Verifies connectivity (gateway ping, internet ping, DNS resolve).

  Idempotent: if the adapter is already static it reports and exits 0.
  Use -WhatIf for a dry run.

.PARAMETER AdapterName
  Optional. Name of the NIC to lock (e.g. 'Ethernet'). If omitted the script
  auto-selects the adapter that currently has a default gateway.

.PARAMETER FallbackDns
  DNS servers to use if the adapter has no DNS configured. Default: 1.1.1.1,8.8.8.8

.PARAMETER LogPath
  Where to write a transcript log. Default: C:\CN-Setup\logs\SetStaticIP-<timestamp>.log

.EXAMPLE
  # Dry run — shows what would change, makes NO changes.
  .\CN-SetStaticIP.ps1 -WhatIf

.EXAMPLE
  # Live run — commits current DHCP lease as static.
  .\CN-SetStaticIP.ps1

.EXAMPLE
  # Live run, explicit adapter.
  .\CN-SetStaticIP.ps1 -AdapterName 'Ethernet'

.NOTES
  Author   : ConnectNest
  Requires : Windows 10/11, PowerShell 5.1+, Administrator privileges
  Version  : 1.0 (2026-04-19)
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$AdapterName,
    [string[]]$FallbackDns = @('1.1.1.1','8.8.8.8'),
    [string]$LogPath
)

# --- Ensure Admin ---------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as Administrator' and re-run." -ForegroundColor Yellow
    exit 1
}

# --- Logging --------------------------------------------------------------
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $LogPath) {
    $logDir = 'C:\CN-Setup\logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $LogPath = Join-Path $logDir "SetStaticIP-$ts.log"
}
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " CN Hub - Lock DHCP Lease as Static IP" -ForegroundColor Cyan
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# --- 1. Find the primary adapter -----------------------------------------
Write-Host "`n[1/6] Locating active network adapter..." -ForegroundColor Yellow

if ($AdapterName) {
    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if (-not $adapter) { Write-Host "ERROR: Adapter '$AdapterName' not found." -ForegroundColor Red; exit 2 }
} else {
    # Pick the adapter bound to the default route
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { Write-Host "ERROR: No default route found. Is the PC online?" -ForegroundColor Red; exit 2 }
    $adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex
}

if ($adapter.Status -ne 'Up') {
    Write-Host "ERROR: Adapter '$($adapter.Name)' is not Up (status: $($adapter.Status))." -ForegroundColor Red
    exit 2
}

$ifIndex = $adapter.ifIndex
Write-Host "  Adapter        : $($adapter.Name)  (ifIndex=$ifIndex)"
Write-Host "  Description    : $($adapter.InterfaceDescription)"
Write-Host "  MAC            : $($adapter.MacAddress)"

# --- 2. Read current IP config -------------------------------------------
Write-Host "`n[2/6] Reading current IPv4 configuration..." -ForegroundColor Yellow

$ipCfg = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
if (-not $ipCfg) { Write-Host "ERROR: No IPv4 address on $($adapter.Name)." -ForegroundColor Red; exit 3 }

$iface = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4
$gateway = (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1).NextHop
$dns = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses

$ipAddress = $ipCfg.IPAddress
$prefix    = $ipCfg.PrefixLength
$isDhcp    = ($iface.Dhcp -eq 'Enabled')

Write-Host "  IP Address     : $ipAddress/$prefix"
Write-Host "  Gateway        : $gateway"
Write-Host "  DNS Servers    : $(if ($dns) { $dns -join ', ' } else { '(none — will use fallback)' })"
Write-Host "  DHCP Enabled   : $isDhcp"

if (-not $gateway) { Write-Host "ERROR: No default gateway detected." -ForegroundColor Red; exit 3 }

if (-not $dns -or $dns.Count -eq 0) {
    Write-Host "  WARN: No DNS on adapter — will apply fallback: $($FallbackDns -join ', ')" -ForegroundColor Yellow
    $dns = $FallbackDns
}

# --- 3. Short-circuit if already static ----------------------------------
if (-not $isDhcp) {
    Write-Host "`n[3/6] Adapter is ALREADY static. Nothing to do." -ForegroundColor Green
    Write-Host "      (If you need to change it, reset with: Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled)" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# --- 4. Apply static config ----------------------------------------------
Write-Host "`n[3/6] Planned changes:" -ForegroundColor Yellow
Write-Host "  * Disable DHCP on $($adapter.Name)"
Write-Host "  * Set static IP   $ipAddress/$prefix  gw $gateway"
Write-Host "  * Set DNS         $($dns -join ', ')"

if ($PSCmdlet.ShouldProcess("$($adapter.Name) [$ipAddress/$prefix gw $gateway]", "Lock DHCP lease as static")) {

    Write-Host "`n[4/6] Disabling DHCP..." -ForegroundColor Yellow
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled -ErrorAction Stop

    # Remove existing gateway/IP to avoid duplicate-address errors
    Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $ipAddress -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host "[5/6] Applying static IP $ipAddress/$prefix via $gateway..." -ForegroundColor Yellow
    New-NetIPAddress -InterfaceIndex $ifIndex `
                     -IPAddress $ipAddress `
                     -PrefixLength $prefix `
                     -DefaultGateway $gateway `
                     -ErrorAction Stop | Out-Null

    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $dns -ErrorAction Stop

} else {
    Write-Host "`n(-WhatIf) — no changes made. Re-run without -WhatIf to commit." -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

# --- 5. Verify ------------------------------------------------------------
Write-Host "`n[6/6] Verifying..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

$verifyIface = Get-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4
$verifyIp    = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).IPAddress
$verifyDns   = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4).ServerAddresses

$okDhcpOff = ($verifyIface.Dhcp -eq 'Disabled')
$okIp      = ($verifyIp -contains $ipAddress)

$gwOk   = Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
$netOk  = Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet -ErrorAction SilentlyContinue
$dnsOk  = $false
try { [System.Net.Dns]::GetHostEntry('home-assistant.io') | Out-Null; $dnsOk = $true } catch {}

function Row($label, $val, $ok) {
    $mark = if ($ok) { 'OK  ' } else { 'FAIL' }
    $col  = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-18} {2}" -f $mark, $label, $val) -ForegroundColor $col
}
Row 'DHCP Disabled' $verifyIface.Dhcp  $okDhcpOff
Row 'Static IP'     $verifyIp          $okIp
Row 'DNS'           ($verifyDns -join ', ') ($verifyDns.Count -gt 0)
Row 'Gateway ping'  $gateway           $gwOk
Row 'Internet ping' '8.8.8.8'          $netOk
Row 'DNS resolve'   'home-assistant.io' $dnsOk

$allOk = $okDhcpOff -and $okIp -and $gwOk -and $netOk -and $dnsOk

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
if ($allOk) {
    Write-Host " SUCCESS — $($adapter.Name) locked at $ipAddress/$prefix" -ForegroundColor Green
    Write-Host ""
    Write-Host " NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "   1. Repeat the equivalent step inside Home Assistant:"
    Write-Host "      HA UI -> Settings -> System -> Network -> (adapter) -> IPv4 -> Static"
    Write-Host "      Use the IP that HA currently shows (from the customer router DHCP table)."
    Write-Host "   2. On the customer router, add a DHCP RESERVATION for BOTH MAC addresses"
    Write-Host "      (Windows NIC + HA VM NIC) as belt-and-braces protection."
    Write-Host "   3. Reboot the Windows host once and confirm the static IP persists."
} else {
    Write-Host " WARNING — one or more checks failed. Review output above." -ForegroundColor Red
    Write-Host " To revert to DHCP:" -ForegroundColor Yellow
    Write-Host "   Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled"
    Write-Host "   Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses"
    Write-Host "   Remove-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $ipAddress -Confirm:`$false"
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Log: $LogPath" -ForegroundColor DarkGray

try { Stop-Transcript | Out-Null } catch {}
if ($allOk) { exit 0 } else { exit 4 }
