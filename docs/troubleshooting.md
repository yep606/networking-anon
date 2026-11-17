# Troubleshooting: Four Failure Modes Seen in Practice

Each of these was diagnosed from real sing-box logs. Symptoms are similar
("no internet" / "test still shows my ISP"), causes are not.

---

## 1. Leak test still shows ISP resolvers

**Symptom.** TUN is up, exit IP is the VPS, but dnsleaktest lists the ISP's
DNS servers (e.g. `203.0.113.x` — your ISP's resolver range).

**Cause.** No DNS hijack rule. The OS keeps its DHCP-assigned ISP resolver;
queries to it enter the TUN and are routed like any other traffic
(`final: proxy`) — i.e. *proxied to the ISP resolver*, which keeps logging
your domains and keeps answering from ISP egress IPs. The `dns` module with
its DoH-through-proxy server is only used for sing-box's internal needs, so
almost nothing ever uses it.

**Fix.** Add the hijack rule (see pitfall #2 for the exact form) so sing-box
answers all port-53 traffic itself.

**Log signature.** `dns: exchanged ...` lines only for sing-box's own needs;
leak test shows ISP resolver IPs.

---

## 2. Total connectivity loss after adding `hijack-dns`

**Symptom.** Applied a route rule `{ "action": "hijack-dns" }` — now nothing
loads at all.

**Cause.** A rule with **no conditions matches every connection**. All TCP
traffic (TLS, HTTP, everything) gets thrown at the DNS module, can't be
parsed, and silently dies. Only real DNS (UDP/53) survives — which is exactly
why this is confusing: name resolution keeps working while every connection
hangs.

**Fix.** Use the canonical pattern from the official migration guide — sniff
first, hijack only DNS:

```json
"rules": [
  { "action": "sniff" },
  { "protocol": "dns", "action": "hijack-dns" },
  { "ip_is_private": true, "action": "route", "outbound": "direct" }
]
```

**Log signature.** Many `inbound connection to X:443` lines with **zero**
corresponding `outbound/vless[proxy]: outbound connection to ...` lines; the
only successful outbound dial is the DoH server (`1.1.1.1:443`).

---

## 3. Connectivity loss after adding an IPv6 address to the TUN

**Symptom.** Added a second TUN address (e.g. `fdfe:dcba:9876::1/126`) to
capture IPv6 — internet dies again.

**Cause.** The OS now believes it has IPv6 connectivity and **prefers it**.
AAAA queries succeed (DNS goes through the working tunnel), so apps connect
to IPv6 destinations — but the VPS is IPv4-only and cannot reach them. Happy
Eyeballs does not save every app; the result is hangs and retries.

**Fix.** Keep the IPv6 TUN address (it's a useful safety net that captures
stray v6 traffic), but stop handing out AAAA records:

```json
"dns": {
  "strategy": "ipv4_only"
}
```

With `ipv4_only`, AAAA queries get empty answers and all traffic uses IPv4,
which the VPS can route. If your VPS actually has IPv6
(`ip -6 addr show scope global`), you can skip this and route v6 properly.

**Log signature.** `dns: exchanged AAAA ... 2a00:...` answers being handed
out, followed by connections that never complete.

---

## 4. Leak persists with a verified-correct config (Windows)

**Symptom.** The sing-box config is provably correct — even a point-blank
`nslookup example.com 203.0.113.10` (the ISP resolver's IP) is hijacked
(visible in the log, answered via the tunnel in ~500 ms) — yet the leak test
still shows the ISP's resolvers, now including the ISP's **IPv6** resolvers.

**Cause.** Windows' DNS Client service uses *smart multi-homed name
resolution*: it fires queries on **every adapter in parallel** via sockets
bound to each physical interface. Interface-bound sockets bypass the VPN/TUN
routes entirely — packets leave through the physical NIC → router → ISP
resolver, never touching the tunnel. IPv6 router advertisements (RDNSS) from
the ISP add a second bypass. Key insight: `nslookup` follows the route table
(so it gets hijacked and looks clean), while the OS resolver's bound sockets
do not — **a clean nslookup probe does NOT prove a clean resolver**.

**Fix.** Run `scripts/Enable-DnsKillswitch.ps1`: it blocks outbound DNS
(UDP/TCP 53 and 853) on the physical interface at the firewall level,
disables the IPv6 binding on that interface, and disables smart multi-homed
name resolution. Revert with `scripts/Disable-DnsKillswitch.ps1`.

**Log signature.** Leak test shows ISP resolvers (v4 and v6) while sing-box
logs show all TUN-arriving DNS hijacked and no ISP-destined packets at all.

---

## 5. GeoIP databases disagree on the VPS country

**Symptom.** The tunnel works (exit IP = VPS IP, DNS test clean), but some
site (e.g. 2ip) shows a *wrong country* for your IP — while ipinfo.io,
dnsleaktest.com and others show the right one.

**Cause.** IP geolocation is not a measurement — it is a lookup in a private
database, and each vendor (MaxMind, ipinfo, DB-IP, 2ip's own DB, ...) keeps
its own mapping that updates at its own speed. VPS providers often announce
**leased/reassigned IP blocks**: a block may originally belong to one RIR
region (e.g. LACNIC), get leased through an IP broker registered in a third
country, and only recently be re-registered to the actual hoster. Any
database holding the *stale* record reports the broker's country instead of
the physical one.

**Diagnosis.** Check the IP against several independent sources:

```bash
curl -s http://ip-api.com/json/<VPS_IP> | jq -r '.country, .city'
curl -s https://ipwho.is/<VPS_IP>     | jq -r '.country, .city'
curl -s https://ipapi.co/<VPS_IP>/json/ | jq -r '.country_name, .city'
```

…plus the [MaxMind GeoIP demo](https://www.maxmind.com/en/geoip-demo) in a
browser (many large services use MaxMind). The ground truth is the RDAP
registration of the block:

```bash
curl -sL https://rdap.org/ip/<VPS_IP> | jq -r '.name, .country'
```

If most providers (especially MaxMind) agree on the right country and one or
two outliers disagree, the outliers are stale — not your config.

**Fix.** Nothing to fix in sing-box. Optionally submit a correction to the
stale provider (2ip has a "change location" link; MaxMind and DB-IP have
correction forms). Databases converge on the new registration within weeks.

**Verdict rule.** A GeoIP mismatch on a minority of databases is *expected
behavior* for freshly leased blocks and is **not** a leak. What counts as a
problem: your home ISP's resolvers in a DNS leak test, or your real IP
showing up anywhere.

---

## Verification checklist

```powershell
# Windows, after restarting sing-box:
ipconfig /flushdns
curl https://ifconfig.me        # must print the VPS IP
nslookup example.com 8.8.8.8    # works — hijacked silently
```

Healthy logs show, for every browser connection:

```
inbound connection to 142.250.x.x:443
outbound/vless[proxy]: outbound connection to 142.250.x.x:443
```

Finally, run the **extended** test at dnsleaktest.com: the expected end
state is a **single ISP** in the results — only your chosen resolver's egress
(e.g. Cloudflare), no ISP servers.

> **Note.** The resolver's geolocation may differ from your VPS location —
> `1.1.1.1` is anycast, so its egress IPs geolocate to a Cloudflare node, not
> to you. That mismatch is normal and is **not** a leak; only the presence of
> your own ISP's resolvers indicates one.
