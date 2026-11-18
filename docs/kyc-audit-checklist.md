# KYC / Browser Traffic Audit Checklist — Windows PC + iPhone

Goal: see **exactly** what a browser or KYC flow sends from your devices
(requests, headers, payloads, uploaded photos) and control what leaks.

Run `scripts/Setup-KycAudit.ps1` first (as Administrator), then work top to bottom.

---

## Part A — Intercept iPhone traffic with mitmproxy

- [ ] **A1.** Start the proxy on the PC: `mitmweb --listen-port 8080`
      (UI opens at http://localhost:8081)
- [ ] **A2.** iPhone and PC on the **same Wi-Fi**.
- [ ] **A3.** iPhone: `Settings → Wi-Fi → ⓘ (your network) → Configure Proxy → Manual`
      Server = PC IP from setup script output, Port = `8080`.
- [ ] **A4.** iPhone Safari: open `http://mitm.it` → tap the Apple icon →
      install the downloaded profile (`Settings → Profile Downloaded`).
- [ ] **A5.** **Critical, most-skipped step:**
      `Settings → General → About → Certificate Trust Settings` →
      enable full trust for the mitmproxy root certificate.
- [ ] **A6.** Sanity check: browse any HTTPS site on the iPhone — requests
      should appear in mitmweb. If nothing shows up, A4/A5 were skipped
      or the firewall blocks 8080.
- [ ] **A7.** Run the KYC / verification flow in Safari. In mitmweb click
      each request → inspect **Request** tab (headers, JSON body, form
      fields, uploaded files).
- [ ] **A8.** Save evidence: in mitmweb `File → Save` the flow, or export
      single requests.

**What you will NOT see:** native apps with certificate pinning (most
native KYC SDKs) will fail TLS through the proxy — the failure itself
confirms pinning. Browser (Safari) flows are almost never pinned.

**Cleanup when done:** iPhone Wi-Fi proxy → Off; optionally remove the
mitmproxy profile and certificate trust.

### A-variant — auditing traffic that goes through sing-box

Setting the iPhone Wi-Fi proxy to the PC **while sing-box runs on the
iPhone does not work the way you'd expect**: mitmproxy makes its own
connections from the PC, so the target service sees the PC's IP, not the
sing-box exit node. Instead, chain them on the PC:

- [ ] **Av1.** Run sing-box on Windows with a local HTTP inbound
      (e.g. `127.0.0.1:10808` — a `mixed` or `http` inbound in config.json).
- [ ] **Av2.** Start mitmproxy in upstream mode:

      mitmweb --listen-port 8080 --mode upstream:http://127.0.0.1:10808

- [ ] **Av3.** iPhone Wi-Fi proxy → PC IP : 8080 (same as A3).
- [ ] **Av4.** Disable sing-box on the iPhone — it now runs on the PC.
- [ ] **Av5.** Chain: iPhone → mitmproxy (decrypted, logged) → sing-box →
      exit node → service. Verify via browserleaks.com/ip from the iPhone:
      must show the exit node's IP.

iPhone-only alternative: **Shadowrocket** (App Store, paid) supports the
same protocols as sing-box and has built-in HTTPS MITM capture — install
its local CA on the phone and it logs all requests while proxying.

---

## Part B — Photo / EXIF audit (before uploading anything)

- [ ] **B1.** Copy the photo from iPhone to PC (or test with any photo).
- [ ] **B2.** Inspect metadata:

      exiftool photo.jpg

      Look for: `GPS Latitude / Longitude`, `Make`, `Model`, `Lens Model`,
      `Date/Time Original`, `Software`.
- [ ] **B3.** Strip all metadata before upload:

      exiftool -all= -o cleaned.jpg photo.jpg

- [ ] **B4.** Verify the cleaned file: `exiftool cleaned.jpg` → GPS/Make/Model gone.
- [ ] **B5.** Prevention at the source: iPhone
      `Settings → Privacy & Security → Location Services → Camera → Never`
      — new photos will have no GPS EXIF at all.
- [ ] **B6.** Note: sharing via iOS share sheet with `Options → Location: off`
      strips GPS too, but a **browser file input usually uploads the
      original file** — strip manually instead (B3).

---

## Part C — If the KYC flow runs in a desktop browser (easier path)

- [ ] **C1.** Do it on the Windows PC instead of the phone when the service
      allows: no proxy needed, DevTools shows everything natively.
- [ ] **C2.** Chrome/Edge: `F12 → Network` tab → run the flow → click
      requests to read payloads. `F12 → Application` shows granted
      permissions (camera, mic, geolocation).
- [ ] **C3.** Fake desktop geolocation if the site asks:
      DevTools → `⋮ → More tools → Sensors → Location → Other…` →
      enter lat/lon. Desktop has no GPS chip, so the browser API is the
      only location source here.
- [ ] **C4.** Camera access: you can feed a virtual camera
      (e.g., OBS Virtual Camera) if the flow allows browser camera
      selection — liveness checks usually detect this, expect rejection.

---

## Part D — IP / WebRTC leak verification (with sing-box or any proxy on)

- [ ] **D1.** Enable your proxy (sing-box client etc.), system-wide or per-app.
- [ ] **D2.** Visit `https://browserleaks.com/ip` — the shown IP/country must
      be your exit node's, not your ISP's.
- [ ] **D3.** Visit `https://browserleaks.com/webrtc` — your **real** IP must
      not appear as a WebRTC candidate. If it does: in Safari
      `Settings → Safari → Advanced → Experimental Features` /
      or use a browser that lets you disable WebRTC.
- [ ] **D4.** DNS check: `https://dnsleaktest.com` (Extended test) — resolver
      should belong to the exit location, not your ISP.

---

## Part E — Consistency check (the part anti-fraud systems actually test)

All signals must tell the same story — one mismatch flags the session:

| Signal | Set by | Matches? |
|---|---|---|
| IP geolocation | proxy exit node | ☐ |
| GPS / Geolocation API | spoofer (dongle / PC tool / DevTools) | ☐ |
| Device timezone | iPhone Settings → Date & Time | ☐ |
| EXIF GPS in uploaded photos | stripped or matching | ☐ |
| Browser language / Accept-Language | iOS language settings | ☐ |

- [ ] **E1.** GPS coords ≈ IP city (same country minimum, same city ideally).
- [ ] **E2.** Timezone matches spoofed location.
- [ ] **E3.** Uploaded photos contain no contradicting EXIF.

---

## Legal note

Auditing your own traffic and stripping metadata from your own photos is
fine. Using spoofing to pass verification for a service that geo-restricts
you violates its ToS and, for regulated services (finance, gambling), can
have legal consequences depending on jurisdiction. Use this kit for
privacy hygiene and for understanding what you leak.
