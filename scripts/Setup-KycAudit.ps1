#Requires -RunAsAdministrator
# setup.ps1 — traffic-audit tooling setup for Windows + iPhone
# Run: powershell -ExecutionPolicy Bypass -File .\setup.ps1

$ErrorActionPreference = "Continue"

Write-Host "=== [1/4] Installing mitmproxy ===" -ForegroundColor Cyan
if (Get-Command mitmweb -ErrorAction SilentlyContinue) {
    Write-Host "mitmproxy already installed: $((Get-Command mitmweb).Source)"
} else {
    winget install --id mitmproxy.mitmproxy -e --accept-source-agreements --accept-package-agreements
}

Write-Host "`n=== [2/4] Installing exiftool ===" -ForegroundColor Cyan
if (Get-Command exiftool -ErrorAction SilentlyContinue) {
    Write-Host "exiftool already installed: $((Get-Command exiftool).Source)"
} else {
    winget install --id OliverBetz.ExifTool -e --accept-source-agreements --accept-package-agreements
}

Write-Host "`n=== [3/4] Firewall: opening port 8080 for mitmproxy ===" -ForegroundColor Cyan
$rule = Get-NetFirewallRule -DisplayName "mitmproxy-8080" -ErrorAction SilentlyContinue
if ($rule) {
    Write-Host "Firewall rule already exists."
} else {
    New-NetFirewallRule -DisplayName "mitmproxy-8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow | Out-Null
    Write-Host "Rule created."
}

Write-Host "`n=== [4/4] Your local IP addresses ===" -ForegroundColor Cyan
Write-Host "Enter one of these as the proxy server on the iPhone (port 8080)." -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.PrefixOrigin -ne "WellKnown" } |
    Format-Table InterfaceAlias, IPAddress -AutoSize

Write-Host "=== Done ===" -ForegroundColor Green
Write-Host @"

Next steps (details in README.md):
  1. Run:         mitmweb --listen-port 8080
  2. On iPhone:   Settings -> Wi-Fi -> (your network) -> Configure Proxy -> Manual
                  Server = IP from the table above, Port = 8080
  3. On iPhone:   open http://mitm.it and install the certificate profile
  4. On iPhone:   Settings -> General -> About -> Certificate Trust Settings
                  -> enable full trust for the mitmproxy certificate
  5. Open http://localhost:8081 on the PC to watch the traffic
"@
