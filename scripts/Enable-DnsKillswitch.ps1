<#
.SYNOPSIS
  Enable DNS killswitch - force ALL DNS through the sing-box tunnel.

.DESCRIPTION
  1. Blocks outbound DNS (UDP/TCP ports 53 and 853) on the physical interface,
     so Windows' per-interface DNS spraying can never reach the ISP resolver.
  2. Disables IPv6 on that interface (ISP IPv6 DNS bypasses the tunnel).
  3. Disables Windows smart multi-homed name resolution (parallel DNS spray).

  Revert everything with Disable-DnsKillswitch.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Enable-DnsKillswitch.ps1
  powershell -ExecutionPolicy Bypass -File .\Enable-DnsKillswitch.ps1 -InterfaceAlias "Ethernet"
#>
param(
    [string]$InterfaceAlias = ""
)

# --- self-elevate to Administrator ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InterfaceAlias `"$InterfaceAlias`""
    exit
}

# --- auto-detect the active internet adapter if not specified ---
# Strategy: the physical adapter carrying the default IPv4 route. If a VPN
# tunnel owns the default route (virtual adapter), fall back to the
# physical "Up" adapter with the lowest interface metric.
if (-not $InterfaceAlias) {
    $physical = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    $candidate = $null
    if ($route) {
        $candidate = $physical | Where-Object InterfaceIndex -eq $route.ifIndex | Select-Object -First 1
    }
    if (-not $candidate) {
        $candidate = $physical | Sort-Object InterfaceMetric | Select-Object -First 1
    }
    if ($candidate) {
        $InterfaceAlias = $candidate.Name
        Write-Host "[*] Auto-detected active adapter: '$InterfaceAlias'"
    }
}

# --- validate the adapter exists ---
if (-not (Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue)) {
    Write-Host "Adapter '$InterfaceAlias' not found. Adapters on this machine:" -ForegroundColor Red
    Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
    Write-Host "Re-run with:  -InterfaceAlias `"<name from the list>`"" -ForegroundColor Yellow
    exit 1
}

# --- 1. firewall killswitch rules (idempotent: recreate if present) ---
$rules = @(
    @{ Name = "KillSwitch-DNS-UDP"; Protocol = "UDP" },
    @{ Name = "KillSwitch-DNS-TCP"; Protocol = "TCP" }
)
foreach ($r in $rules) {
    if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $r.Name
    }
    New-NetFirewallRule -DisplayName $r.Name -Direction Outbound -Action Block `
        -Protocol $r.Protocol -RemotePort 53,853 -InterfaceAlias $InterfaceAlias | Out-Null
    Write-Host "[+] Rule '$($r.Name)': DNS ($($r.Protocol) 53/853) blocked on '$InterfaceAlias'"
}

# --- 2. disable IPv6 on the interface ---
Disable-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6
Write-Host "[+] IPv6 disabled on '$InterfaceAlias'"

# --- 3. disable smart multi-homed name resolution ---
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name "DisableSmartNameResolution" -Value 1 -Type DWord
Write-Host "[+] Smart multi-homed name resolution disabled"

Restart-Service dnscache
Clear-DnsClientCache

Write-Host ""
Write-Host "DNS killswitch is ON. All DNS now goes through the tunnel only." -ForegroundColor Green
Write-Host "NOTE: with sing-box OFF there will be no DNS (by design). Run Disable-DnsKillswitch.ps1 to revert." -ForegroundColor Yellow
