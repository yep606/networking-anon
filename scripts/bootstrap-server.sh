#!/usr/bin/env bash
# bootstrap-server.sh - install and configure sing-box (VLESS + Reality) on a
# fresh Ubuntu 24.04 VPS.
#
# What it does (phases 4-9 of docs/server-setup-guide.md):
#   1. verifies the Reality handshake host is reachable
#   2. installs sing-box from the official SagerNet apt repo
#   3. generates UUID / Reality keypair / short_id into root-only files
#   4. writes /etc/sing-box/config.json and runs sing-box check
#   5. configures UFW (OpenSSH first, then 443/tcp)
#   6. enables and starts the service, verifies the listener
#   7. prints the CLIENT-side values (public key etc.) once, for your
#      local client profile
#
# What it deliberately does NOT do:
#   - create users or harden SSH (do that first, phase 3 of the guide)
#   - back up existing configs (fresh servers only; it refuses to run if a
#     sing-box config already exists)
#
# Usage (as root, or via sudo):
#   curl -fsSL <this script> -o bootstrap-server.sh
#   chmod +x bootstrap-server.sh
#   sudo ./bootstrap-server.sh
#   # or with a custom handshake host:
#   sudo REALITY_HANDSHAKE_HOST=www.example.com ./bootstrap-server.sh
#
# Overridable environment variables:
#   REALITY_HANDSHAKE_HOST  (default: www.microsoft.com)
#   LISTEN_PORT             (default: 443)
#   SECRETS_DIR             (default: /root/reality-setup)
set -euo pipefail

REALITY_HANDSHAKE_HOST="${REALITY_HANDSHAKE_HOST:-www.microsoft.com}"
LISTEN_PORT="${LISTEN_PORT:-443}"
SECRETS_DIR="${SECRETS_DIR:-/root/reality-setup}"
CONFIG=/etc/sing-box/config.json

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
[ -e "$CONFIG" ] && die "$CONFIG already exists - refusing to overwrite. Back up or remove it first."

# --- 1. handshake host reachable -------------------------------------------
info "checking Reality handshake host: $REALITY_HANDSHAKE_HOST"
code=$(curl -sI -m 10 "https://$REALITY_HANDSHAKE_HOST" -o /dev/null -w '%{http_code}' || true)
case "$code" in 2*|3*) ok "handshake host answers HTTPS ($code)" ;; *) die "https://$REALITY_HANDSHAKE_HOST unreachable (got '$code')" ;; esac

# --- 2. install sing-box ----------------------------------------------------
if ! command -v sing-box >/dev/null 2>&1; then
  info "installing sing-box from the official SagerNet repo"
  apt-get update -qq
  apt-get install -y -qq curl openssl jq ufw >/dev/null
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -qq
  apt-get install -y -qq sing-box >/dev/null
fi
sing-box version | head -1

# --- 3. secrets -------------------------------------------------------------
info "generating secrets into $SECRETS_DIR (mode 700/600)"
install -d -m 700 "$SECRETS_DIR"
UUID=$(sing-box generate uuid)
KP=$(sing-box generate reality-keypair)
PRIV=$(printf '%s\n' "$KP" | awk '/PrivateKey/ {print $2}')
PUB=$(printf '%s\n' "$KP" | awk '/PublicKey/ {print $2}')
SID=$(openssl rand -hex 4)
[ -n "$UUID" ] && [ -n "$PRIV" ] && [ -n "$PUB" ] && [ -n "$SID" ] || die "secret generation failed"
umask 077
printf 'UUID=%s\nREALITY_PRIVATE_KEY=%s\nREALITY_PUBLIC_KEY=%s\nSHORT_ID=%s\n' \
  "$UUID" "$PRIV" "$PUB" "$SID" > "$SECRETS_DIR/secrets.env"
chmod 600 "$SECRETS_DIR/secrets.env"
ok "secrets stored in $SECRETS_DIR/secrets.env"

# --- 4. server config -------------------------------------------------------
info "writing $CONFIG"
mkdir -p /etc/sing-box
cat > "$CONFIG" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "listen_port": $LISTEN_PORT,
      "users": [ { "uuid": "$UUID", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_HANDSHAKE_HOST",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_HANDSHAKE_HOST", "server_port": 443 },
          "private_key": "$PRIV",
          "short_id": ["$SID"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
chmod 600 "$CONFIG"
sing-box check -c "$CONFIG" || die "sing-box check failed - service NOT started"
ok "sing-box check passed"

# --- 5. firewall ------------------------------------------------------------
info "configuring UFW (OpenSSH first, then $LISTEN_PORT/tcp)"
ufw allow OpenSSH >/dev/null
ufw allow "$LISTEN_PORT"/tcp >/dev/null
yes | ufw enable >/dev/null
ufw status | grep -E '22/tcp|OpenSSH'  >/dev/null || die "UFW lost the SSH rule - aborting"
ufw status | grep -q "$LISTEN_PORT/tcp" || die "UFW lost the $LISTEN_PORT rule - aborting"
ok "UFW active: OpenSSH + $LISTEN_PORT/tcp allowed"

# --- 6. service -------------------------------------------------------------
info "enabling and starting sing-box"
systemctl enable --now sing-box >/dev/null 2>&1
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 20 --no-pager; die "service not active"; }
ss -ltn | grep -q ":$LISTEN_PORT " || die "no listener on :$LISTEN_PORT"
ok "sing-box active, listening on 0.0.0.0:$LISTEN_PORT"

# --- 7. handoff -------------------------------------------------------------
SERVER_IP=$(curl -s -m 10 https://api.ipify.org || echo '<could not detect>')
cat <<EOF

============================================================================
 SERVER READY - copy these into your LOCAL client profile (configs/client.json),
 then clear your scrollback/screen. Do not paste them into chats or tickets.
============================================================================
   server (YOUR_SERVER_IP)          : $SERVER_IP
   server_port                      : $LISTEN_PORT
   uuid (YOUR_UUID)                 : $UUID
   tls.server_name                  : $REALITY_HANDSHAKE_HOST
   reality.public_key (YOUR_...)    : $PUB
   reality.short_id (YOUR_SHORT_ID) : $SID
============================================================================
 Secrets also live in $SECRETS_DIR/secrets.env (root-only).
 Remaining manual checks: start the client, confirm 'curl https://ifconfig.me'
 prints the VPS IP, run the extended test on dnsleaktest.com, then test Stop.
============================================================================
EOF
