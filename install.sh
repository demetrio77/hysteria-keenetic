#!/bin/sh
#
# hysteria-keenetic installer for Keenetic routers with Entware
# Run: sh install.sh
#

set -e

INSTALL_DIR="/opt/etc/hysteria-keenetic"
SINGBOX_BIN="/opt/bin/sing-box"
INIT_SCRIPT="/opt/etc/init.d/S99hysteria-keenetic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[install] $1"; }
err() { echo "[install] ERROR: $1" >&2; exit 1; }

# ── Pre-checks ───────────────────────────────────────────────────

log "hysteria-keenetic installer"
log "==========================="
echo ""

[ "$(id -u)" = "0" ] || err "Run as root"
command -v opkg >/dev/null 2>&1 || err "Entware (opkg) not found"

# Check for Netfilter kernel modules (required for ipset matching)
netfilter_ok=1
ipset create _hy_test_set hash:net 2>/dev/null || netfilter_ok=0
if [ "$netfilter_ok" = "1" ]; then
    if ! iptables -t nat -A OUTPUT -m set --match-set _hy_test_set dst -j RETURN 2>/dev/null; then
        netfilter_ok=0
    else
        iptables -t nat -D OUTPUT -m set --match-set _hy_test_set dst -j RETURN 2>/dev/null
    fi
    ipset destroy _hy_test_set 2>/dev/null
fi

if [ "$netfilter_ok" = "0" ]; then
    ipset destroy _hy_test_set 2>/dev/null
    log ""
    log "WARNING: Netfilter kernel modules do not appear to be working."
    log ""
    log "Enable in Keenetic web interface:"
    log "  Management -> System Settings -> Change component set"
    log "  -> OPKG Packages -> Netfilter kernel modules"
    log ""
    log "Then reboot the router and re-run this installer."
    log ""
    printf "Continue anyway? [y/N] "
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || exit 1
else
    log "Netfilter modules: OK"
fi

# Check for TUN device (required for sing-box TUN mode)
if [ -c /dev/net/tun ]; then
    log "TUN device: OK"
else
    log ""
    log "WARNING: /dev/net/tun is not available."
    log "TUN mode requires the tun kernel module."
    log ""
    printf "Continue anyway? [y/N] "
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || exit 1
fi

# ── Install dependencies ─────────────────────────────────────────

log "Installing dependencies..."
opkg update
for pkg in iptables ipset dnsmasq-full curl ca-certificates conntrack bind-dig dnscrypt-proxy2 sing-box-go; do
    if opkg list-installed | grep -q "^$pkg "; then
        log "  $pkg: already installed"
    else
        log "  $pkg: installing..."
        opkg install "$pkg" || log "  WARNING: failed to install $pkg"
    fi
done

# Verify sing-box works
if [ -x "$SINGBOX_BIN" ]; then
    SB_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log "sing-box installed: v$SB_VER"
else
    err "sing-box binary not found after installation. Check opkg output."
fi

# ── Copy files ────────────────────────────────────────────────────

log "Installing files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/scripts"

# Config handling
if [ -f "$INSTALL_DIR/config" ]; then
    log "  config: exists, keeping current"
    if [ -f "$SCRIPT_DIR/config.example" ]; then
        cp "$SCRIPT_DIR/config.example" "$INSTALL_DIR/config.example"
        log "  config.example: updated (reference)"
    fi
elif [ -f "$SCRIPT_DIR/config" ]; then
    # User already created config from config.example
    cp "$SCRIPT_DIR/config" "$INSTALL_DIR/config"
    log "  config: installed"
elif [ -f "$SCRIPT_DIR/config.example" ]; then
    cp "$SCRIPT_DIR/config.example" "$INSTALL_DIR/config"
    cp "$SCRIPT_DIR/config.example" "$INSTALL_DIR/config.example"
    log "  config: installed from template"
    echo ""
    echo "  +--------------------------------------------------------+"
    echo "  |  IMPORTANT: Edit config before starting!               |"
    echo "  |  vi $INSTALL_DIR/config"
    echo "  |  Set HY_SERVER and HY_PASSWORD                         |"
    echo "  +--------------------------------------------------------+"
    echo ""
else
    err "Neither config nor config.example found in $SCRIPT_DIR"
fi

# Custom domains — don't overwrite
if [ ! -f "$INSTALL_DIR/custom-domains.txt" ]; then
    cp "$SCRIPT_DIR/custom-domains.txt" "$INSTALL_DIR/custom-domains.txt"
fi

# Scripts
cp "$SCRIPT_DIR/scripts/manage.sh" "$INSTALL_DIR/scripts/manage.sh"
cp "$SCRIPT_DIR/scripts/update-domains.sh" "$INSTALL_DIR/scripts/update-domains.sh"
chmod +x "$INSTALL_DIR/scripts/"*.sh

# Copy uninstall script
cp "$SCRIPT_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

# ── Generate configs from templates ──────────────────────────────

log "Generating configs..."
. "$INSTALL_DIR/config"

# sing-box config is generated dynamically by manage.sh at start time.
# It reads all config variables and creates sing-box.json with correct
# Hysteria 2 outbound, TUN inbound, and SOCKS5 inbound.
log "  sing-box.json: will be generated on start (from config variables)"

# dnsmasq config — uses dnscrypt-proxy (DNS via VPS) as upstream
# This ensures CDN IP selection is optimal for VPS location
cat > "$INSTALL_DIR/dnsmasq.conf" << EOF
# hysteria-keenetic dnsmasq instance
port=${DNSMASQ_PORT:-5300}
no-resolv
no-poll
no-dhcp-interface=
bind-dynamic
server=127.0.0.1#5301
cache-size=8192
min-cache-ttl=300
neg-ttl=60
conf-file=$INSTALL_DIR/dnsmasq-ipset.conf
EOF
log "  dnsmasq.conf: generated (upstream: dnscrypt-proxy on :5301)"

# dnscrypt-proxy config — resolves DNS through sing-box SOCKS5 proxy
cat > /opt/etc/dnscrypt-proxy.toml << EOF
listen_addresses = ["127.0.0.1:5301"]
max_clients = 100
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
require_dnssec = false
require_nolog = false
require_nofilter = true
force_tcp = true
proxy = "socks5://127.0.0.1:1080"
timeout = 5000
cache = true
cache_size = 4096
cache_min_ttl = 300
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
server_names = ["google", "cloudflare"]
bootstrap_resolvers = ["1.1.1.1:53", "8.8.8.8:53"]
ignore_system_dns = true
log_level = 2
[sources]
  [sources.public-resolvers]
    urls = ["https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md", "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"]
    cache_file = "/opt/etc/dnscrypt-proxy/public-resolvers.md"
    minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3"
EOF
mkdir -p /opt/etc/dnscrypt-proxy
log "  dnscrypt-proxy.toml: generated (DNS via SOCKS5 proxy)"

# Empty ipset conf (will be populated by update)
touch "$INSTALL_DIR/dnsmasq-ipset.conf"

# ── Test dnsmasq ipset support ────────────────────────────────────

log "Testing dnsmasq ipset support..."
echo "ipset=/test.example.com/testset" > /tmp/test-ipset.conf
cat > /tmp/test-dnsmasq.conf << EOF
port=15353
no-resolv
server=8.8.8.8
conf-file=/tmp/test-ipset.conf
EOF

if dnsmasq --test --conf-file=/tmp/test-dnsmasq.conf 2>&1 | grep -q "OK"; then
    log "  dnsmasq ipset: supported"
else
    log "  dnsmasq ipset: NOT supported"
    log "  WARNING: DNS-based ipset will not work."
    log "  Make sure dnsmasq-full is installed (not just dnsmasq)."
fi
rm -f /tmp/test-ipset.conf /tmp/test-dnsmasq.conf

# ── Init script ──────────────────────────────────────────────────

cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh
/opt/etc/hysteria-keenetic/scripts/manage.sh "$@"
EOF
chmod +x "$INIT_SCRIPT"
log "Init script: $INIT_SCRIPT"

# Convenience symlink
ln -sf "$INSTALL_DIR/scripts/manage.sh" /opt/bin/hysteria-keenetic 2>/dev/null
log "Command: hysteria-keenetic {start|stop|restart|update|upgrade|status}"

# NDM netfilter hook — restores iptables rules when Keenetic rebuilds firewall
mkdir -p /opt/etc/ndm/netfilter.d
cp "$SCRIPT_DIR/scripts/netfilter-hook.sh" /opt/etc/ndm/netfilter.d/100-hysteria.sh
chmod +x /opt/etc/ndm/netfilter.d/100-hysteria.sh
log "Netfilter hook: /opt/etc/ndm/netfilter.d/100-hysteria.sh"

# ── Cron job ──────────────────────────────────────────────────────

. "$INSTALL_DIR/config"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 4 * * *}"
CRON_LINE="$CRON_SCHEDULE $INSTALL_DIR/scripts/manage.sh update >/dev/null 2>&1"

# Ensure crontabs directory exists
mkdir -p /opt/etc/crontabs

# Add cron if not exists
if crontab -l 2>/dev/null | grep -q "hysteria-keenetic"; then
    log "Cron: already configured"
else
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    log "Cron: added ($CRON_SCHEDULE)"
fi

# Ensure cron daemon is running
if ! pidof crond >/dev/null 2>&1; then
    /opt/etc/init.d/S10cron start 2>/dev/null || crond 2>/dev/null
    log "Cron daemon: started"
fi

# ── Clean up old Hysteria binary ──────────────────────────────────

if [ -x "/opt/bin/hysteria" ]; then
    log "Removing old Hysteria binary..."
    killall hysteria 2>/dev/null
    rm -f /opt/bin/hysteria
    log "  /opt/bin/hysteria: removed"
fi

# Clean up old hysteria.yaml if exists
if [ -f "$INSTALL_DIR/hysteria.yaml" ]; then
    log "  hysteria.yaml: kept as backup (no longer used)"
fi

# ── Download initial domain lists ────────────────────────────────

log "Downloading domain lists (first run)..."
sh "$INSTALL_DIR/scripts/update-domains.sh"

# ── Done ──────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "  Config:  $INSTALL_DIR/config"
echo "  Domains: $INSTALL_DIR/custom-domains.txt"
echo ""
echo "  Commands:"
echo "    hysteria-keenetic start    # Start VPN routing"
echo "    hysteria-keenetic stop     # Stop everything"
echo "    hysteria-keenetic restart  # Restart"
echo "    hysteria-keenetic update   # Update domain lists"
echo "    hysteria-keenetic upgrade  # Update sing-box via opkg"
echo "    hysteria-keenetic status   # Check status"
echo ""
echo "  Auto-update: $CRON_SCHEDULE"
echo ""
echo "  To start now:  hysteria-keenetic start"
echo "  To uninstall:  sh $INSTALL_DIR/uninstall.sh"
echo ""
