# Full Server Setup Guide: VPS → sing-box → Verified Tunnel

Step-by-step guide for turning a fresh VPS into a personal VLESS + Reality
endpoint with a leak-free sing-box client. Everything below was executed and
verified in practice (Ubuntu 24.04, sing-box 1.14.x, Windows client).

> **All values here are placeholders.** `203.0.113.10` is from the
> documentation-only TEST-NET-3 range (RFC 5737) — substitute your real VPS
> IP. Never commit real IPs, UUIDs, keys, or `short_id` values.

**Time:** ~15 minutes. **You need:** root SSH access to a fresh Ubuntu 24.04
VPS with a public IPv4, and an SSH key on your local machine.

## Architecture (target state)

```
local apps ──► TUN ──► sing-box client ──► VLESS+Reality TCP/443 ──► sing-box on VPS ──► internet
```

Hard rules:

- Only sing-box runs on the VPS. No dev tools, projects, tokens, browsers.
- Secrets live on the server in root-only files; the client profile stays
  local, mode 600, never committed, never sent through chat/messengers.
- After every phase: verify PASS before continuing. On FAIL — stop.

---

## Phase 0 — Collect inputs

Write these into a scratch note before touching anything:

```text
VPS_PUBLIC_IPV4=203.0.113.10          # your real server IP
VPS_ADMIN_USER=proxyuser              # new sudo user to create
REALITY_HANDSHAKE_HOST=www.microsoft.com
LOCAL_PROFILE_OUTPUT_PATH=~/network/my-vps.json
```

Choosing `REALITY_HANDSHAKE_HOST`: a popular site with TLSv1.3 and HTTP/2
that **opens from the VPS** on TCP/443. You verify this in Phase 4.

---

## Phase 1 — Preflight (read-only)

```bash
ssh root@203.0.113.10
```

```bash
uname -a && lsb_release -a        # expect Ubuntu 24.04, x86_64 or arm64
ss -ltnp                          # TCP/443 must be FREE (only :22 sshd is fine)
ufw status verbose 2>/dev/null    # understand existing firewall state
ls /etc/sing-box 2>/dev/null      # no unknown pre-existing config
curl -sI -m 10 https://www.microsoft.com -o /dev/null -w '%{http_code}\n'   # expect 200/301/302
```

**PASS:** SSH works, port 443 free, no unknown config, handshake host
reachable. If 443 is occupied — stop, identify the process first.

---

## Phase 2 — Safety

This guide assumes a **fresh** server. If it's not fresh:

```bash
mkdir -p /root/backups && tar czf /root/backups/pre-singbox-$(date +%Y%m%d-%H%M%S).tgz \
  /etc/ssh /etc/sing-box 2>/dev/null || true
```

Do not overwrite an unknown working configuration. Do not close your initial
SSH session until a *new* login path is proven (Phase 3).

---

## Phase 3 — Admin user + SSH hardening

Why: root login over the internet is the #1 scanned target. Create a sudo
user, verify it, *then* lock root.

```bash
# still as root
useradd -m -s /bin/bash proxyuser
usermod -aG sudo proxyuser
mkdir -p /home/proxyuser/.ssh
cp /root/.ssh/authorized_keys /home/proxyuser/.ssh/authorized_keys
chown -R proxyuser:proxyuser /home/proxyuser/.ssh
chmod 700 /home/proxyuser/.ssh
chmod 600 /home/proxyuser/.ssh/authorized_keys
echo 'proxyuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/proxyuser
chmod 440 /etc/sudoers.d/proxyuser
```

**Verify in a second terminal** (keep the root session open!):

```bash
ssh proxyuser@203.0.113.10 'sudo whoami'    # must print: root
```

Only after that succeeds, harden sshd:

```bash
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
sshd -t                       # syntax check; MUST be silent
systemctl reload ssh
```

**Verify again:** a fresh `ssh proxyuser@203.0.113.10` works and
`ssh root@203.0.113.10` is refused with `Permission denied (publickey)`.
Rollback if the new login fails: from the still-open root session,
`rm /etc/ssh/sshd_config.d/00-hardening.conf && systemctl reload ssh`.

**PASS:** new user works, root is locked. From here on, all commands run as
`proxyuser` with `sudo`.

---

## Phase 4 — Reality handshake host check

```bash
curl -sI -m 10 https://www.microsoft.com -o /dev/null -w '%{http_code}\n'
```

**PASS:** 200/301/302. If unreachable, pick another popular host and re-check.
Do not issue your own certificate or use your own domain — Reality borrows
the handshake host's TLS identity (see
[protocol-explained.md](protocol-explained.md#4-reality--why-this-doesnt-look-like-a-proxy)).

---

## Phase 5 — Install sing-box (official SagerNet repo)

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key | sudo tee /etc/apt/keyrings/sagernet.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/sagernet.asc

cat <<'EOF' | sudo tee /etc/apt/sources.list.d/sagernet.sources
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

sudo apt-get update
sudo apt-get install -y sing-box jq
sing-box version
```

**PASS:** version prints (this guide was verified with 1.14.x). Record it.

---

## Phase 6 — Generate secrets

```bash
sing-box generate uuid
sing-box generate reality-keypair
openssl rand -hex 4
```

Store them root-only, never in shell history of a shared account, never in
chat:

```bash
sudo install -d -m 700 /root/reality-setup
sudo tee /root/reality-setup/secrets.env >/dev/null <<'EOF'
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
REALITY_PRIVATE_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
REALITY_PUBLIC_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
SHORT_ID=xxxxxxxx
EOF
sudo chmod 600 /root/reality-setup/secrets.env
```

- private key → **server only**
- public key + UUID + short_id → go into the client profile
- to fill them without re-typing: `sudo cat /root/reality-setup/secrets.env`
  in your own terminal only.

---

## Phase 7 — Server config

```bash
sudo mkdir -p /etc/sing-box
```

Write `/etc/sing-box/config.json` (fill from `secrets.env`, or see the
annotated template in [`configs/server.example.json`](../configs/server.example.json)):

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [ { "uuid": "YOUR_UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.microsoft.com", "server_port": 443 },
          "private_key": "YOUR_REALITY_PRIVATE_KEY",
          "short_id": ["YOUR_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
```

```bash
sudo chmod 600 /etc/sing-box/config.json
sudo sing-box check -c /etc/sing-box/config.json
```

**PASS:** check exits silently with code 0. On any error — fix the config,
do **not** start the service.

---

## Phase 8 — Firewall

```bash
sudo apt-get install -y ufw     # some minimal images lack it
sudo ufw allow OpenSSH          # FIRST — or you lock yourself out
sudo ufw allow 443/tcp
sudo ufw enable                 # answer y
sudo ufw status verbose
```

**PASS:** `Status: active`, rules list `22/tcp` and `443/tcp`, and your
current SSH session is still alive. If the provider has a separate cloud
firewall (check the hosting panel), allow TCP/22 and TCP/443 there too.

---

## Phase 9 — Service

```bash
sudo systemctl enable --now sing-box
sudo systemctl is-active sing-box            # expect: active
sudo ss -ltnp | grep ':443'                  # expect: sing-box listener
sudo journalctl -u sing-box --output cat -n 20 --no-pager
```

**PASS:** active + listener on `0.0.0.0:443` + log line
`inbound/vless[vless-in]: tcp server started at 0.0.0.0:443`, no errors.
This proves the *server* runs — it does **not** yet prove end-to-end.

---

## Phase 10 — Client profile

Copy [`configs/client.json`](../configs/client.json) locally, fill the four
placeholders from `secrets.env`, save to your `LOCAL_PROFILE_OUTPUT_PATH`:

| Placeholder | Value |
| --- | --- |
| `YOUR_SERVER_IP` | `VPS_PUBLIC_IPV4` |
| `YOUR_UUID` | `UUID` |
| `YOUR_REALITY_PUBLIC_KEY` | `REALITY_PUBLIC_KEY` (the **public** one) |
| `YOUR_SHORT_ID` | `SHORT_ID` |

```bash
sing-box check -c <profile>.json     # validate with a matching sing-box version
chmod 600 <profile>.json
```

The file already contains the full DNS-leak fix (hijack + DoH via tunnel +
`ipv4_only`); on Windows add the OS-level killswitch **before** starting:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-DnsKillswitch.ps1 -InterfaceAlias "Wi-Fi"
```

(Find your adapter name with `Get-NetAdapter`; use the **physical** one.
Revert anytime with `Disable-DnsKillswitch.ps1`.)

Import into your sing-box client (e.g. SFM: `+ → Import from File → Local →
Create → select profile → Play`), or run directly with admin rights:
`sing-box run -c <profile>.json`.

---

## Phase 11 — Verify (this is what "done" means)

With the tunnel **off**, record baseline: `curl -s https://ifconfig.me`.

With the tunnel **on**:

```bash
curl -s https://ifconfig.me    # MUST print the VPS IP
curl -sI https://example.com -o /dev/null -w '%{http_code}\n'
```

Then:

1. **Extended test on [dnsleaktest.com](https://dnsleaktest.com)** — expect
   one ISP (Cloudflare), never your own. See
   [dns-leak-explained.md](dns-leak-explained.md) for why and
   [troubleshooting.md](troubleshooting.md) if it fails.
2. **[browserleaks.com/webrtc](https://browserleaks.com/webrtc)** — no
   unwanted public address.
3. **Stop test** — disable the tunnel; your original IP must come back and
   the internet must keep working.

**GREEN** = IP matches the VPS + DNS clean + Stop restores the route.
An active service and an open port alone are **not** proof.

---

## Phase 12 — Cleanup

- Delete temporary copies of the profile (Downloads/Desktop) after import.
- Secrets remain only in `/root/reality-setup/secrets.env` (server) and the
  imported client profile (local). Nothing in Git, chat, QR codes, or
  messenger history.

---

## Quick reference: what broke last time

| Symptom | First thing to check |
| --- | --- |
| Profile won't start | Client version vs. config fields; run `sing-box check` |
| Service active, no connection | UFW + provider firewall + listener on 443 |
| IP doesn't change | Profile actually selected? `auto_route: true`? |
| DNS dead | Hijack rule scoped to `protocol: dns`? DoH `detour` set? |
| `authentication failed` | UUID / short_id / keypair mismatch between ends |
| `TLS mismatch` | `server_name` ≠ handshake host, wrong public key |
| Leak test shows ISP | Windows killswitch not enabled (failure mode 4) |

Never "fix" TLS errors with `insecure: true`.
