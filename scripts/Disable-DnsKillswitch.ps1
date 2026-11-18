<#
.SYNOPSIS
  Disable DNS killswitch - restore normal direct internet.

.DESCRIPTION
  Reverts everything Enable-DnsKillswitch.ps1 did:
  1. Removes the firewall rules blocking DNS on the physical interface.
  2. Re-enables IPv6 on that interface.
  3. Restores Windows smart multi-homed name resolution.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Disable-DnsKillswitch.ps1
  powershell -ExecutionPolicy Bypass -File .\Disable-DnsKillswitch.ps1 -InterfaceAlias "Ethernet"
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

# --- auto-detect the active internet adapter if not specified (same
# logic as Enable-DnsKillswitch.ps1). Firewall rules are removed by name
# regardless; the adapter is only needed to re-enable IPv6.
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

# --- 1. remove firewall killswitch rules ---
foreach ($name in "KillSwitch-DNS-UDP", "KillSwitch-DNS-TCP") {
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $name
        Write-Host "[+] Removed firewall rule '$name'"
    }
    else {
        Write-Host "[=] Rule '$name' not present, skipping"
    }
}

# --- 2. re-enable IPv6 on the interface ---
if (Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue) {
    Enable-NetAdapterBinding -Name $InterfaceAlias -ComponentID ms_tcpip6
    Write-Host "[+] IPv6 re-enabled on '$InterfaceAlias'"
}
else {
    Write-Host "[!] Adapter '$InterfaceAlias' not found - skipped IPv6 step" -ForegroundColor Yellow
}

# --- 3. restore smart multi-homed name resolution ---
$regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
if ((Test-Path $regPath) -and (Get-ItemProperty -Path $regPath -Name "DisableSmartNameResolution" -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty -Path $regPath -Name "DisableSmartNameResolution"
    Write-Host "[+] Smart multi-homed name resolution restored"
}
else {
    Write-Host "[=] Smart multi-homed policy not set, skipping"
}

Restart-Service dnscache
Clear-DnsClientCache

Write-Host ""
Write-Host "DNS killswitch is OFF. Normal direct internet restored." -ForegroundColor Green
