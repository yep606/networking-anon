# Troubleshooting: Three Failure Modes Seen in Practice

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

Finally, run the **extended** test at dnsleaktest.com: only your chosen
resolver's egress (e.g. Cloudflare) should appear — no ISP servers.
