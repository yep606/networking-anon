# How It Works: sing-box + VLESS + Reality, Schematically

This document explains the moving parts of the setup so the configuration in
this repo stops being magic. Every field in
[`configs/client.json`](../configs/client.json) and
[`configs/server.example.json`](../configs/server.example.json) maps to
something described here.

---

## 1. The big picture

```
┌──────────────────────────── local device ────────────────────────────┐
│                                                                      │
│   apps (browser, CLI tools, anything)                                │
│        │                                                             │
│        ▼                                                             │
│   ┌─────────┐   DNS query to port 53                                 │
│   │   TUN   │──────────────► hijacked, answered by sing-box itself   │
│   │ (virtual│                        │ (DoH to 1.1.1.1 *via proxy*)  │
│   │   NIC)  │                        ▼                               │
│   │         │   TCP/UDP flows ──► route rules ──► VLESS outbound     │
│   └─────────┘                                            │           │
│                                                          │           │
└──────────────────────────────────────────────────────────┼───────────┘
                                                           │
                              VLESS + Reality over TCP/443 │
                              (looks like ordinary HTTPS   │
                               to www.example.com)         │
                                                           ▼
┌──────────────────────────── VPS ─────────────────────────────────────┐
│   ┌───────────────────────────────────────────────────────────┐      │
│   │ sing-box server: VLESS inbound on 0.0.0.0:443             │      │
│   │   1. Reality handshake  (proves client, mimics real site) │      │
│   │   2. VLESS auth         (UUID inside the TLS channel)     │      │
│   │   3. direct outbound    (plain forward to the internet)   │      │
│   └───────────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────────────┘
```

One sentence: **every packet from your device enters a virtual network
adapter (TUN), DNS is intercepted and resolved through the tunnel, and all
other traffic is wrapped in a TLS session that is indistinguishable from a
real HTTPS connection to a well-known site, then unwrapped on the VPS and
forwarded to the internet.**

---

## 2. sing-box — the engine

sing-box is a universal proxy platform: one binary, many protocols, one JSON
config. The same program runs on both ends with different configs:

- **On the VPS** the config describes *inbounds* (what to accept — a VLESS
  listener on TCP/443) and *outbounds* (where to send it — `direct`, i.e.
  plain forwarding).
- **On your device** the config describes a TUN *inbound* (a virtual network
  interface that captures all OS traffic), *route rules* (sniff, hijack DNS,
  private ranges direct), and a VLESS *outbound* (the tunnel to the VPS).

Key concepts used in both configs:

| Concept | Meaning |
| --- | --- |
| `inbound` | Where traffic enters sing-box (TUN locally, VLESS listener on the server). |
| `outbound` | Where traffic leaves sing-box (`proxy` = VLESS to VPS, `direct` = as-is). |
| `route.rules` | First-match-wins decisions applied to each connection. |
| `detour` | "Use this outbound for my own connections" — used so the DoH resolver itself goes through the tunnel. |
| `tag` | A name so rules/detours can reference an inbound/outbound/DNS server. |

---

## 3. VLESS — the proxy protocol

VLESS is a minimal proxy protocol: it carries "who you are" (a UUID) and
"where to connect" (target host/port) with almost no extra bytes. No
encryption of its own — encryption comes from the TLS layer below it.

```
client                                    server
  │  inside the established TLS channel:     │
  │  ┌──────────────────────────────────┐    │
  │  │ UUID │ command │ target addr:port│───►│ check UUID → dial target
  │  └──────────────────────────────────┘    │
  │◄── proxied bytes, both directions ───────│
```

- **UUID** is the only credential. Treat it like a password: one leak and
  anyone can use your server. Never commit it.
- **`flow: xtls-rprx-vision`** is a performance/steganography mode for
  VLESS-over-TLS: after the handshake, sing-box splices the raw encrypted
  streams together instead of decrypt-then-re-encrypt (TLS-in-TLS) on both
  ends. Fewer copies, less CPU, no double-TLS traffic pattern that DPI can
  fingerprint. Required on **both** ends or authentication fails.

---

## 4. Reality — why this doesn't look like a proxy

Classic "VPN over TLS" setups need a domain and a certificate, and the server
itself terminates TLS — a censor probing the port gets a certificate for
*your* domain, which is fingerprintable and blockable.

**Reality removes the server-side certificate entirely.** Instead, the server
borrows the TLS identity of a real, popular site (the *handshake host*, e.g.
`www.example.com`).

What happens when a client connects:

```
client                                VPS (sing-box)              real site
  │  1. TLS ClientHello                  │                          │
  │     SNI = www.example.com            │                          │
  │     + Reality proof encrypted with   │                          │
  │       the server's PUBLIC key ──────►│                          │
  │                                      │ 2. valid proof?          │
  │                                      │    YES: answer the       │
  │                                      │    handshake locally     │
  │  3. real certificate chain ◄─────────│    relayed from the ────►│
  │     of www.example.com (forwarded    │    target                │
  │     byte-for-byte, unforgeable)      │                          │
  │                                      │    NO proof (prober,     │
  │                                      │    browser, censor):     │
  │                                      │    act as a dumb relay ─►│ full normal
  │                                      │    to the real site      │ HTTPS session
```

Consequences:

- **Active probing is useless.** A scanner connecting to your VPS port 443
  sees a perfectly valid TLS session with the real certificate chain of the
  handshake host — because it literally *is* relayed from that host.
- **Only someone with the public key can produce a valid proof**, and only
  the server (holding the private key) can read it. The keypair is generated
  once with `sing-box generate reality-keypair`.
- **`short_id`** is a small extra secret mixed into the proof; think of it as
  a second password. It must match on both ends.
- **`server_name` (client) = `handshake.server` (server) = the SNI.** All
  three refer to the same real hostname. Mismatch → `TLS mismatch` errors.
- **No domain, no certificate, no ACME, nothing to renew.** The handshake
  host just needs to be a popular TLSv1.3 + H2 site reachable from the VPS.
- Never set `insecure: true` to "fix" TLS errors — that disables the very
  verification that makes this safe.
- **`utls` fingerprint (`chrome`)** makes the ClientHello byte-pattern match
  a real Chrome browser instead of Go's TLS stack, removing the last easy
  fingerprint.

---

## 5. TUN — how all traffic gets captured

On the client, sing-box creates a virtual network interface with
`auto_route: true`, which rewrites the OS routing table so all traffic
points at the TUN. Apps don't know anything changed.

Two gotchas, both covered in [troubleshooting](troubleshooting.md):

- The IPv6 TUN address makes the OS *prefer* IPv6; if the VPS is IPv4-only,
  pair it with `"strategy": "ipv4_only"` so no AAAA records are handed out.
- On Windows, the OS DNS resolver binds sockets to the physical adapter and
  **bypasses the routing table entirely** — that's why the firewall
  killswitch scripts in [`scripts/`](../scripts) exist.

---

## 6. The DNS path, step by step

Why the client config looks the way it does:

```
app asks: "example.com ?"
   │
   ▼
OS resolver sends UDP to port 53 (usually the ISP resolver from DHCP)
   │
   ▼
TUN captures it → route rules:
   1. { "action": "sniff" }                  → protocol detected: "dns"
   2. { "protocol": "dns",
        "action": "hijack-dns" }            → sing-box answers it itself,
                                              the ISP resolver never sees it
   │
   ▼
sing-box DNS module → "dns-via-proxy" server:
   DoH request to https://1.1.1.1/dns-query with detour: "proxy"
   │                                          (i.e. through the VLESS tunnel,
   ▼                                           so even the DNS lookup exits
answer returns                                from the VPS)
```

Rule order matters: **sniff first, hijack only DNS.** A bare
`{ "action": "hijack-dns" }` matches *every* connection and kills the
internet (failure mode 2 in [troubleshooting](troubleshooting.md)).

---

## 7. Field-by-field cheat sheet

| Field | Where | Why it exists |
| --- | --- | --- |
| `tun.address` | client | IPs of the virtual interface; also decide v4/v6 capture. |
| `tun.auto_route` | client | Rewrites OS routes so everything enters the tunnel. |
| `tun.stack: mixed` | client | Compatibility+performance balance for the userspace TCP/IP stack. |
| `dns.servers[].type: https` | client | DoH instead of plaintext DNS. |
| `dns.servers[].detour: proxy` | client | The DoH lookup itself exits via the VPS — no DNS to the ISP. |
| `dns.strategy: ipv4_only` | client | Don't promise IPv6 the VPS can't deliver. |
| `route.rules: sniff → hijack-dns` | client | Intercept port-53 traffic, answer locally. |
| `ip_is_private → direct` | client | LAN (printers, routers, NAS) never enters the tunnel. |
| `route.final: proxy` | client | Everything else goes through the VPS. |
| `auto_detect_interface` | client | Survive Wi-Fi ↔ Ethernet switches. |
| `vless.server/server_port` | client | Your VPS IP and 443. |
| `vless.uuid` | both | The credential. Must match. |
| `vless.flow` | both | `xtls-rprx-vision`, must match. |
| `tls.server_name` | both | SNI = the handshake host. Must match. |
| `tls.utls.fingerprint: chrome` | client | Mimic a real browser's TLS ClientHello. |
| `reality.public_key` | client | Used to encrypt the Reality proof. |
| `reality.private_key` | server only | Proves the server; **never leaves the VPS**. |
| `reality.short_id` | both | Second secret, must match. |
| `reality.handshake.server` | server | Where to relay handshakes of non-clients (the real site). |
| `vless.listen: 0.0.0.0` | server | Accept connections on all server interfaces. |
| `outbounds: direct` | server | Forward traffic to the internet as-is. |

---

## 8. Threat model in one paragraph

A network observer between you and the VPS sees: TCP/443 to one IP, TLS 1.3,
SNI of a popular website, a real certificate chain from that website, and
traffic sizes/timing like ordinary browsing. They cannot list your domains
(DNS is inside the tunnel), cannot prove it's a proxy by probing (probes get
relayed to the real site), and cannot decrypt (they'd need the Reality
private key on the VPS). What they *can* see: that you talk to one specific
IP a lot, and for how long. Choose the VPS provider and location with that
in mind.
