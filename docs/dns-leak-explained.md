# DNS Leaks, Explained

## What a DNS leak is

DNS is the lookup step before almost every connection: your machine asks a
resolver "what IP is `example.com`?" and only then connects. Whoever runs the
resolver sees **every domain you look up**.

A **DNS leak** is when your traffic goes through a tunnel (VPN / proxy /
sing-box TUN), but some DNS queries still reach a resolver **outside the
tunnel** — typically the one your ISP assigned via DHCP. Consequences:

- Your ISP still sees which sites you visit (the resolver *is* theirs).
- Test pages see resolvers from two networks — your tunnel exit **and** your
  real ISP — exposing the mismatch.

## The subtle case: a leak through the tunnel

Routing DNS queries *through* the tunnel is not enough if the destination
resolver is still the ISP's. If your OS uses the ISP's DNS servers, sing-box
faithfully tunnels those queries to them — the transport is hidden from the
ISP's routers, but the ISP's resolver still logs every domain you ask about,
and leak tests still see the ISP's resolver egress IPs. The fix is not just
routing but **hijacking**: answer all DNS locally (in sing-box) via a resolver
of your choice, reached through the tunnel.

## How leak tests detect you (and why it's not in the HTTP request)

A plain HTTP(S) request carries only your source IP and headers — there is no
"DNS" field. Detection is a **side channel**:

1. The page embeds a **unique, never-before-seen hostname**
   (e.g. `a9f3.z-leak.test`) as a resource URL. The name is generated
   server-side, per page load — your browser only triggers the lookup.
2. Because the name was never seen, no cache can answer it — every configured
   resolver is forced to ask the **authoritative DNS server** for that zone,
   which the tester runs themselves.
3. The tester correlates two logs they own:
   - web log → your connection's source IP (the VPS);
   - authoritative DNS log → the source IPs of all resolvers that asked
     (Cloudflare via the tunnel *and* the ISP resolver directly).
4. Mismatch = tunneled user; the resolver IPs reveal the real ISP and region.

Key properties:

- **The unique name is the glue, not TCP and not timestamps.** DNS mostly runs
  over UDP; the correlation happens afterwards at the application layer by
  matching the unique string. Only your browser ever asks for that exact name,
  so any resolver querying it is working on your behalf.
- Uniqueness is required because DNS is cached everywhere: a static name could
  be answered from a shared resolver's cache, breaking both detection and
  attribution.
- **Any website can do this** — with its own zone, or via third-party
  callback services (canarytokens, Burp Collaborator, interactsh) that hand
  out unique subdomains and report incoming DNS queries. CDN operators that
  host both a site's DNS and its web traffic get the same correlation
  passively.
- Even in the worst case the test sees your **resolver's** IP, not your home
  IP directly — but that identifies your ISP/region, proves tunneling, and
  your ISP's own logs map those queries to your line.

## What else betrays you

Even with zero DNS leaks: `Accept-Language` headers, JavaScript-reported
timezone, and WebRTC can each contradict your "foreign" exit IP.

## The fix used in this repo

- `sniff` + `protocol: "dns"` → `hijack-dns`: sing-box answers every port-53
  query itself, regardless of which resolver IP the OS asked.
- The DNS module uses DoH (`https://1.1.1.1/dns-query`) with
  `detour: proxy` — the lookup exits from the VPS, so authoritative servers
  only ever see Cloudflare egress via the VPS.
- `"strategy": "ipv4_only"` on IPv4-only VPSes, so clients never attempt
  unreachable IPv6 destinations.
