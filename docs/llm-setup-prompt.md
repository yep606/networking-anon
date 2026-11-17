# LLM Setup Prompt: Configure a New VPS as a VLESS + Reality Endpoint

This is a **ready-made prompt**. Copy the whole block below into a fresh LLM
session (one that has terminal/SSH access on your machine), fill in the
`INPUT DATA` section, and it will configure the server end-to-end following
the same phases as [server-setup-guide.md](server-setup-guide.md).

Design goals:

- **Parameterized** — all per-server values are variables at the top.
- **Secret-safe** — the model is explicitly forbidden from printing,
  logging, or committing secrets; real values never belong in this file.
- **Verifiable** — each phase ends with a PASS/FAIL gate; the model must
  stop on FAIL instead of piling changes on top of errors.
- **Self-sufficient** — the prompt embeds the full plan, so the model does
  not need this repo to be present (but linking the repo helps).

> ⚠️ Keep this file free of real data. Fill in a **copy** in your local
> scratch space, not the committed version.

---

## The prompt (copy from here)

```text
You are a systems engineer. Configure my VPS as a personal network endpoint:

local apps -> sing-box client with TUN -> VLESS + Reality over TCP/443 -> sing-box on VPS -> internet

HARD INVARIANTS
- Only sing-box and necessary system components go on the VPS. No dev tools,
  no projects, no browsers, no tokens.
- Never print, log, commit, or transmit: UUIDs, Reality private/public keys,
  short_id, the full client profile JSON, QR/URI exports, or full logs.
  Refer to secrets by name only. The private key never leaves the server.
- Never use insecure=true. Never "fix" TLS errors by disabling verification.
- Work phase by phase. Before each phase state what changes and how to roll
  back. After each phase show PASS/FAIL with a short sanitized proof.
  On FAIL: stop.
- Do not close the original SSH session until a new login path is verified.
- Do not change multiple things at once.
- If a critical input below is missing, list ONLY the missing fields and stop.

INPUT DATA
VPS_PUBLIC_IPV4=[SERVER IPv4, e.g. 203.0.113.10]
VPS_SSH_USER=[INITIAL SSH USER, usually root]
VPS_ADMIN_USER=[NEW SUDO USER TO CREATE, e.g. proxyuser]
VPS_SSH_PORT=[22]
VPS_OS=[Ubuntu 24.04 LTS expected — verify, adapt if different]
REALITY_HANDSHAKE_HOST=[e.g. www.microsoft.com — must be reachable from VPS on TCP/443]
LOCAL_CLIENT_OS=[Windows / macOS / Linux]
LOCAL_PROFILE_OUTPUT_PATH=[local path for the client JSON, e.g. ~/network/my-vps.json]
LOCAL_PHYSICAL_INTERFACE=[Windows only: adapter for the DNS killswitch, e.g. Wi-Fi]

EXECUTION PLAN (follow in order)

1. PREFLIGHT (read-only)
   Verify SSH access, OS version/arch, that TCP/443 is free, existing
   firewall state, absence of unknown sing-box configs, and that
   REALITY_HANDSHAKE_HOST answers HTTPS from the VPS.

2. SAFETY
   If the server is not fresh, create a timestamped backup of /etc/ssh and
   /etc/sing-box. Never overwrite an unknown working config.

3. ADMIN USER + SSH HARDENING
   Create VPS_ADMIN_USER with sudo, copy root's authorized_keys, verify a
   fresh login in a SEPARATE connection. Only then add
   /etc/ssh/sshd_config.d/00-hardening.conf with:
     PermitRootLogin no / PasswordAuthentication no /
     KbdInteractiveAuthentication no / PubkeyAuthentication yes
   Run sshd -t before reload; verify a fresh login after reload; confirm
   root login is now refused.

4. INSTALL SING-BOX
   Official SagerNet apt repo only (sing-box.app/gpg.key, deb.sagernet.org).
   Install sing-box + jq. Record the installed version.

5. GENERATE SECRETS
   sing-box generate uuid; sing-box generate reality-keypair;
   openssl rand -hex 4. Store in /root/reality-setup/secrets.env with
   directory mode 700 and file mode 600. Do not echo the values.

6. SERVER CONFIG
   /etc/sing-box/config.json: VLESS inbound on 0.0.0.0:443, one user with
   the generated UUID and flow xtls-rprx-vision, TLS enabled with
   server_name = REALITY_HANDSHAKE_HOST, Reality enabled (handshake server =
   REALITY_HANDSHAKE_HOST:443, generated private_key, generated short_id),
   outbound direct. chmod 600. MUST pass: sing-box check -c ... — if not,
   fix the config; do not start the service.

7. FIREWALL
   Install ufw if missing. Allow OpenSSH FIRST, then 443/tcp, then enable.
   Verify rules and that the SSH session survives. If the provider has a
   separate cloud firewall, give me exact manual steps for the panel.

8. SERVICE
   systemctl enable --now sing-box. Verify: is-active, ss -ltnp shows the
   443 listener, journal has "tcp server started at 0.0.0.0:443" and no
   errors. State clearly: this proves the server only, not end-to-end.

9. CLIENT PROFILE
   Write a local sing-box client JSON at LOCAL_PROFILE_OUTPUT_PATH with:
   - TUN inbound, addresses 172.19.0.1/30 + fdfe:dcba:9876::1/126,
     auto_route true, stack mixed
   - DNS: one https server 1.1.1.1/dns-query with detour to the proxy
     outbound; final = that server; strategy ipv4_only
   - route rules IN THIS ORDER: { "action": "sniff" },
     { "protocol": "dns", "action": "hijack-dns" },
     { "ip_is_private": true, "action": "route", "outbound": "direct" };
     final = proxy; auto_detect_interface true
   - VLESS outbound: VPS IP, port 443, generated UUID, flow
     xtls-rprx-vision, TLS with server_name = REALITY_HANDSHAKE_HOST,
     utls fingerprint chrome, Reality with the PUBLIC key and short_id
   - chmod 600. No extra fields my client version won't understand;
     validate with sing-box check if a local sing-box exists.
   Do NOT paste the file contents into the chat — just confirm the path.

10. DNS LEAK PROTECTION (client OS specific)
    - Windows: apply a firewall killswitch on LOCAL_PHYSICAL_INTERFACE:
      block outbound UDP+TCP ports 53 and 853 on that interface, disable
      the IPv6 binding on it, set
      HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\DisableSmartNameResolution=1,
      restart dnscache. Provide the matching revert script. Warn that with
      the killswitch on, DNS exists only while the tunnel is up.
    - macOS/Linux: verify resolver follows routes; note that no killswitch
      is needed if leak test is clean.

11. HANDOFF REPORT (sanitized — no secrets, mask the IP as 203.0.113.x)
    1. Status: READY_FOR_TEST / BLOCKED
    2. What was installed; sing-box version
    3. sing-box check result; service state; masked listener proof
    4. Client profile path (not contents)
    5. Remaining manual steps in my client app
    6. Rollback steps per phase

12. VERIFICATION (after I start the profile manually)
    Guide me through: ifconfig.me before/after (must become the VPS IP),
    extended test on dnsleaktest.com (only the chosen resolver, never my
    ISP), browserleaks.com/webrtc, and the Stop test (original IP returns,
    internet keeps working). Verdict GREEN only if all pass.
```

---

## Usage notes

- **One server per session.** Don't reuse a session that configured server A
  to configure server B — stale secrets in context are a leak risk.
- If the model skips a PASS/FAIL gate or offers to print secrets, stop it —
  that's exactly the failure mode this prompt is designed to prevent.
- The prompt assumes SSH key auth is already working for the initial user
  (`ssh-keygen -t ed25519` + adding the public key at VPS creation). If you
  only have a password, set up key auth first, then run the prompt.
- Background reading for whoever/whatever runs it:
  [protocol-explained.md](protocol-explained.md) (why each field exists),
  [server-setup-guide.md](server-setup-guide.md) (the same plan written for
  humans), [troubleshooting.md](troubleshooting.md) (known failure modes).
