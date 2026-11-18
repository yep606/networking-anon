# Anti-Detect Browsers with a sing-box Endpoint

When a plain browser through the tunnel is enough, when you need an
anti-detect browser, which free ones are worth using (independently tested,
late 2026), and how to wire one into your sing-box setup without breaking
the DNS-leak guarantees.

---

## 1. Do you need one at all?

```
Your goal                                      Tool you need
─────────────────────────────────────────────  ────────────────────────────
One identity, geo-consistent browsing          Plain browser + this repo's
(card country = IP country = account country)  TUN config. Done.

Several isolated identities on one machine     Anti-detect browser
(ad accounts, e-commerce, testing)             (per-profile fingerprint,
                                               cookies, proxy)
```

An anti-detect browser manages **browser fingerprints** (canvas, WebGL,
fonts, timezone, UA...) per profile. It does **not** change your IP — that
part stays on sing-box/proxies. The two tools solve different layers and
compose well.

---

## 2. Free tiers, tested (late 2026)

Free plans change often; this table reflects independent testing that ran
each browser through Pixelscan, Iphey, and CreepJS on clean IPs.

| Browser | Free plan | Fingerprint test result | Notes |
| --- | --- | --- | --- |
| **GoLogin** | 3 profiles, no time limit | **Passes** | Best free default. Win/macOS/Linux + Android. No API on free. |
| **AdsPower** | 2 profiles, forever | Passes | RPA builder + Synchronizer included on free. Vendor registered in China — consider if that matters to you. |
| **MoreLogin** | 2 profiles, forever | Passes | **Local API (Selenium/Puppeteer) even on the free plan** — the developer pick. |
| **Nstbrowser** | 500 profiles, 30 launches/day | Untested at scale | Volume/scraping niche; newer, less proven. |
| **Kameleo** | unlimited local + 100 cloud profiles, 300 min/mo | Passes | Deep control, REST API from free plan; minutes burn fast. |
| **Dolphin Anty** | 5 profiles | **FAILED both checkers** ("masking detected"; local API caught via localhost scan) | Popular in affiliate circles; avoid for stealth-critical work. |
| **Incogniton** | 10 profiles for 2 months → then 3 | **Flagged even after tuning** | Weakest stealth of the tested set. |

**Recommendation: start with GoLogin** (free 3 profiles, no time limit).
If you need automation for free, MoreLogin or AdsPower.

---

## 3. Wiring it to sing-box: two modes

### Mode A — system-wide TUN (what this repo's `client.json` does)

```
antidetect browser ──┐
any other app ───────┼──► TUN (auto_route) ──► VLESS+Reality ──► VPS ──► internet
system DNS ──────────┘    + DNS hijack + killswitch (Windows)
```

- ✅ Zero per-profile setup; the DNS-leak fix from this repo covers everything.
- ❌ All profiles share the VPS IP (fine for one identity, wrong for
  per-profile-IP setups).
- ❌ Requires admin rights and the Windows killswitch dance.

### Mode B — local SOCKS5 inbound (recommended for anti-detect use)

Run sing-box as a **local proxy only** (no TUN, no admin rights, no
killswitch) and point each browser profile at it:

```
┌─ antidetect profile 1 ──proxy: socks5h://127.0.0.1:1080 ─┐
├─ antidetect profile 2 ──proxy: socks5h://127.0.0.1:1080 ─┼─► sing-box (mixed inbound)
├─ antidetect profile 3 ──proxy: socks5h://127.0.0.1:1080 ─┘         │
└─ everything else on the PC ──► direct, untouched                   ▼
                                              VLESS+Reality ──► VPS ──► internet
```

Use [`configs/client-socks.json`](../configs/client-socks.json) for this
mode. Key points:

- **DNS-leak-free by construction**: with `socks5h` (remote DNS) the browser
  sends the *hostname*, not a DNS query — resolution happens on the VPS.
  No hijack rules or firewall killswitch needed.
- **Critical setting**: in the browser profile's proxy settings choose
  **SOCKS5 with remote DNS** (GoLogin: proxy type SOCKS5; it resolves
  remotely by default). If a browser offers "resolve DNS locally", turn it
  **off** — that reintroduces the leak.
- No admin rights needed; other apps on the machine are unaffected.
- All profiles using this inbound share the VPS exit IP — same as Mode A.
  Per-profile different IPs require multiple upstreams, which is outside
  this repo's scope.

---

## 4. Self-check: what the fingerprint examiners look for

Run each profile through these (free, browser-based) before real use:

| Tool | What it examines | Typical failure |
| --- | --- | --- |
| **CreepJS** (`abrahamjuliot.github.io/creepjs`) | Detects *API tampering itself*: overridden native functions, prototype pollution, inconsistent values across window/iframe/worker contexts | Anti-detect injected JS that CreepJS can see; "lies" report non-empty |
| **Pixelscan** (`pixelscan.net`) | Cross-signal consistency: UA ↔ fonts ↔ codecs ↔ WebGL ↔ timezone ↔ IP geo ↔ DNS resolver geo | "Masking detected" = signals contradict each other (e.g. Windows UA + macOS fonts) |
| **Iphey** (`iphey.com`) | Browser consistency **+ IP reputation** (datacenter vs residential, proxy/blacklist ranges) **+ localhost port scan** | Flags local API servers of anti-detect browsers (e.g. a known port answering on 127.0.0.1) |

Practical rules:

- **Close automation/local API features when not needed.** A listening
  localhost port for the browser's automation API is detectable by any
  website — Iphey caught Dolphin Anty exactly this way.
- **Time zone and language must match the exit IP's country.** Your VPS is
  Kazakhstan → profile timezone `Asia/Almaty`, languages `kk/ru/en`.
- **DNS resolver geo must match too.** This is what this repo's DNS fix
  guarantees in Mode A; in Mode B it holds as long as remote DNS is on.
- **A datacenter IP scores lower than residential**, no matter how good the
  fingerprint is. Your VPS (hosting ASN) will be classified as datacenter —
  acceptable for geo-consistency use, a known limitation for strict
  multi-accounting.
- Passing a checker means the profile is *internally consistent*, not that a
  platform can't link accounts — behavior (cookies, logins, timing) decides
  the rest.

---

## 5. Quick start (GoLogin + Mode B)

```text
1. Run sing-box with configs/client-socks.json (no admin needed):
     sing-box run -c client-socks.json
2. GoLogin → New Profile → Proxy → SOCKS5 → host 127.0.0.1, port 1080
3. Set profile timezone/language to match the VPS country
4. Open iphey.com and pixelscan.net inside the profile — expect green
5. Only then log into anything you care about
```
