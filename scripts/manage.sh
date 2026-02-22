#!/bin/sh
#
# hysteria-keenetic — Selective VPN routing for Keenetic routers
# Usage: hysteria-keenetic {start|stop|restart|update|upgrade|status}
#
# Components: sing-box (redirect+tproxy+Hysteria2+SOCKS5) + dnscrypt-proxy (DNS via VPS)
#            + dnsmasq (DNS->ipset) + iptables (REDIRECT for TCP, TPROXY for UDP)
#

PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BASE_DIR="/opt/etc/hysteria-keenetic"
CONFIG="$BASE_DIR/config"
IPSET_NAME="unblock"
DNSMASQ_PID_FILE="/tmp/hysteria-dnsmasq.pid"

# Load config
[ -f "$CONFIG" ] || { echo "Error: $CONFIG not found"; exit 1; }
. "$CONFIG"

# Defaults for optional config values
DNSMASQ_PORT="${DNSMASQ_PORT:-5300}"
LAN_IF="${LAN_IF:-br0}"
FWMARK="${FWMARK:-2}"
ROUTE_TABLE="${ROUTE_TABLE:-101}"
FORCE_DNS="${FORCE_DNS:-1}"

SINGBOX_BIN="/opt/bin/sing-box"
SINGBOX_CONF="$BASE_DIR/sing-box.json"
SINGBOX_MARK=200
REDIRECT_PORT=2500
TPROXY_PORT=2501

DNSMASQ_CONF="$BASE_DIR/dnsmasq.conf"
DNSCRYPT_BIN="/opt/sbin/dnscrypt-proxy"
DNSCRYPT_CONF="/opt/etc/dnscrypt-proxy.toml"
DNSCRYPT_PORT=5301
UPDATE_SCRIPT="$BASE_DIR/scripts/update-domains.sh"

log() { logger -s -t "hysteria-keenetic" "$1"; }

# ── Config validation ─────────────────────────────────────────────

validate_config() {
    errors=0

    if [ -z "$HY_SERVER" ] || [ "$HY_SERVER" = "your-server.com:443" ]; then
        log "Error: HY_SERVER is not configured in $CONFIG"
        errors=$((errors + 1))
    fi

    if [ -z "$HY_PASSWORD" ] || [ "$HY_PASSWORD" = "your-password-here" ]; then
        log "Error: HY_PASSWORD is not configured in $CONFIG"
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        log ""
        log "Edit your config: vi $CONFIG"
        log "Set HY_SERVER to your Hysteria 2 server address (e.g., mydomain.com:443)"
        log "Set HY_PASSWORD to your server password"
        return 1
    fi
    return 0
}

# ── Load TPROXY kernel modules ────────────────────────────────────

load_tproxy_modules() {
    for mod in xt_socket xt_TPROXY; do
        f="/lib/modules/$(uname -r)/${mod}.ko"
        if [ -f "$f" ]; then
            insmod "$f" 2>/dev/null
        fi
    done
}

# Add RETURN rules for private/reserved IP ranges to an iptables chain
_add_private_ip_rules() {
    _table=$1; _chain=$2
    for _range in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
                  172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t "$_table" -A "$_chain" -d "$_range" -j RETURN
    done
}

# ── Start ────────────────────────────────────────────────────────

do_start() {
    if ! _start_internal; then
        log "Start failed, rolling back..."
        do_stop
        return 1
    fi
}

_start_internal() {
    log "Starting hysteria-keenetic..."

    # Validate config first
    validate_config || return 1

    # Check binaries
    if [ ! -x "$SINGBOX_BIN" ]; then
        log "Error: sing-box not found at $SINGBOX_BIN"
        log "Install with: opkg install sing-box-go"
        return 1
    fi
    for bin in dnsmasq ipset iptables; do
        command -v "$bin" >/dev/null 2>&1 || { log "Error: $bin not found. Run install.sh"; return 1; }
    done

    # Load TPROXY modules (needed for UDP)
    load_tproxy_modules

    # ── 1. Generate sing-box config ──
    _generate_singbox_config

    # Validate config
    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>/dev/null; then
        log "Error: sing-box config validation failed"
        "$SINGBOX_BIN" check -c "$SINGBOX_CONF" 2>&1 | while read -r line; do log "  $line"; done
        return 1
    fi

    # ── 2. Start sing-box (redirect + tproxy + SOCKS5 + Hysteria2) ──
    if pidof sing-box >/dev/null 2>&1; then
        log "  sing-box: already running"
    else
        "$SINGBOX_BIN" run -c "$SINGBOX_CONF" >/dev/null 2>&1 &
        sleep 3
        if pidof sing-box >/dev/null 2>&1; then
            log "  sing-box: started (redirect :$REDIRECT_PORT, tproxy :$TPROXY_PORT, SOCKS5 :1080)"
        else
            log "  sing-box: FAILED to start"
            return 1
        fi
    fi

    # ── 2a. dnscrypt-proxy (DNS via VPS SOCKS5) ──
    # DNS resolution through VPS ensures CDN IPs are optimal for VPS location
    if [ -x "$DNSCRYPT_BIN" ]; then
        if pidof dnscrypt-proxy >/dev/null 2>&1; then
            log "  dnscrypt-proxy: already running"
        else
            "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" >/dev/null 2>&1 &
            sleep 3
            if pidof dnscrypt-proxy >/dev/null 2>&1; then
                log "  dnscrypt-proxy: started (port $DNSCRYPT_PORT via SOCKS5)"
            else
                log "  dnscrypt-proxy: FAILED to start, falling back to direct DNS"
            fi
        fi
    else
        log "  dnscrypt-proxy: not installed (using direct DNS)"
    fi

    # ── 3. IPSet ──
    ipset create "$IPSET_NAME" hash:net maxelem 131072 2>/dev/null
    log "  ipset: created"

    # ── 3a. Load static CIDRs into ipset ──
    LOADED=0
    if [ -f "$BASE_DIR/static-ips.lst" ] && [ -s "$BASE_DIR/static-ips.lst" ]; then
        COUNT_BEFORE=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        sed '/^$/d; /^#/d' "$BASE_DIR/static-ips.lst" | awk "{print \"add $IPSET_NAME \" \$0}" | ipset restore -exist 2>/dev/null
        COUNT_AFTER=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        LOADED=$((COUNT_AFTER - COUNT_BEFORE))
    fi
    [ "$LOADED" -gt 0 ] && log "  ipset: pre-loaded $LOADED static IPs/CIDRs"

    # ── 4. Update domains (downloads lists, generates dnsmasq config) ──
    if [ ! -f "$BASE_DIR/dnsmasq-ipset.conf" ] || [ ! -s "$BASE_DIR/dnsmasq-ipset.conf" ]; then
        log "  domains: downloading..."
        sh "$UPDATE_SCRIPT"
    else
        log "  domains: using cached list ($(wc -l < "$BASE_DIR/dnsmasq-ipset.conf") rules)"
    fi

    # ── 5. dnsmasq ──
    DNSMASQ_PID=$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)
    if [ -n "$DNSMASQ_PID" ] && [ -d "/proc/$DNSMASQ_PID" ]; then
        log "  dnsmasq: already running"
    else
        if ! dnsmasq --test --conf-file="$DNSMASQ_CONF" 2>/dev/null; then
            log "  dnsmasq: WARNING — ipset may not be supported, testing..."
            if ! dnsmasq --test --port="$DNSMASQ_PORT" --no-resolv --server=8.8.8.8 2>/dev/null; then
                log "  dnsmasq: FAILED config test"
                return 1
            fi
        fi
        dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID_FILE"
        sleep 1
        if [ -f "$DNSMASQ_PID_FILE" ]; then
            log "  dnsmasq: started on port $DNSMASQ_PORT"
        else
            log "  dnsmasq: FAILED to start"
            return 1
        fi
    fi

    # ── 6. iptables ──

    # === TCP: REDIRECT to sing-box (nat PREROUTING) ===
    # REDIRECT changes destination to localhost:port, sing-box recovers
    # original dst via SO_ORIGINAL_DST. Different kernel path than TPROXY —
    # avoids kernel 4.9 TPROXY TCP bugs with long-lived connections (SSE).
    iptables -t nat -N HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -F HYSTERIA_REDIRECT

    # Skip private/special ranges
    _add_private_ip_rules nat HYSTERIA_REDIRECT

    # Redirect TCP to sing-box
    iptables -t nat -A HYSTERIA_REDIRECT -p tcp -j REDIRECT --to-ports "$REDIRECT_PORT"

    # Insert BEFORE Keenetic's _NDM_DNAT chain (position 1)
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT

    log "  iptables: TCP REDIRECT to :$REDIRECT_PORT"

    # === UDP: TPROXY to sing-box (mangle PREROUTING) ===
    # TPROXY for UDP works fine on kernel 4.9 (QUIC/YouTube never had issues).
    # Policy routing sends marked packets to loopback where TPROXY socket listens.
    iptables -t mangle -N HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -F HYSTERIA_TPROXY

    # Skip private/special ranges
    _add_private_ip_rules mangle HYSTERIA_TPROXY

    # TPROXY UDP to sing-box with fwmark
    iptables -t mangle -A HYSTERIA_TPROXY -p udp -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "0x$FWMARK/0x$FWMARK"

    # Insert in PREROUTING (only for ipset-matched IPs)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -I PREROUTING 1 -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY

    # Policy routing for TPROXY: marked packets go to local loopback
    ip rule del fwmark "0x$FWMARK" table "$ROUTE_TABLE" 2>/dev/null
    ip rule add fwmark "0x$FWMARK" table "$ROUTE_TABLE"
    ip route replace local default dev lo table "$ROUTE_TABLE"

    log "  iptables: UDP TPROXY to :$TPROXY_PORT (fwmark 0x$FWMARK)"

    # === DNS: redirect LAN DNS to our dnsmasq ===
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    iptables -t nat -I PREROUTING 1 -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
    iptables -t nat -I PREROUTING 2 -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"

    log "  iptables: DNS redirect to :$DNSMASQ_PORT"

    # ── 7. Force DNS through dnsmasq (block DoH/DoT) ──
    if [ "$FORCE_DNS" = "1" ]; then
        ipset create force_dns hash:ip 2>/dev/null
        ipset flush force_dns 2>/dev/null
        for ip in \
            8.8.8.8 8.8.4.4 \
            1.1.1.1 1.0.0.1 \
            9.9.9.9 149.112.112.112 \
            208.67.222.222 208.67.220.220 \
            94.140.14.14 94.140.15.15 \
            185.228.168.9 185.228.169.9; do
            ipset add force_dns "$ip" 2>/dev/null
        done

        # Block DNS-over-TLS (port 853)
        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j DROP 2>/dev/null
        iptables -I FORWARD 1 -i "$LAN_IF" -p tcp --dport 853 -j DROP
        iptables -I FORWARD 2 -i "$LAN_IF" -p udp --dport 853 -j DROP

        # Block DNS-over-HTTPS to known providers
        iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
        iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
        iptables -I FORWARD 3 -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j DROP
        iptables -I FORWARD 4 -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j DROP

        log "  iptables: DoH/DoT blocking enabled"
    fi

    # ── 8. Flush conntrack ──
    if command -v conntrack >/dev/null 2>&1; then
        conntrack -F 2>/dev/null
        log "  conntrack: flushed"
    fi

    # ── 9. DNS warm-up ──
    if command -v dig >/dev/null 2>&1; then
        for domain in youtube.com www.youtube.com googlevideo.com \
                      www.google.com google.com play.google.com \
                      i.ytimg.com yt3.ggpht.com \
                      facebook.com www.facebook.com \
                      twitter.com x.com \
                      instagram.com www.instagram.com \
                      discord.com gateway.discord.gg \
                      api.openai.com t.me; do
            dig "$domain" @127.0.0.1 -p "$DNSMASQ_PORT" +short +time=5 +tries=1 >/dev/null 2>&1
        done
        IPCOUNT=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
        log "  DNS warm-up: $IPCOUNT IPs in ipset"
    fi

    IPCOUNT=$(ipset list "$IPSET_NAME" 2>/dev/null | tail -n +8 | wc -l)
    log "Started. $IPCOUNT IPs in ipset. TCP via REDIRECT, UDP via TPROXY."
}

# ── Generate sing-box config ─────────────────────────────────────

_generate_singbox_config() {
    # Parse server address (host:port)
    HY_HOST=$(echo "$HY_SERVER" | sed 's/:[0-9]*$//')
    HY_PORT=$(echo "$HY_SERVER" | grep -o '[0-9]*$')
    [ -z "$HY_PORT" ] && HY_PORT=443

    # TLS insecure
    TLS_INSECURE="false"
    [ "$HY_TLS_INSECURE" = "1" ] && TLS_INSECURE="true"

    # Obfuscation block
    OBFS_BLOCK=""
    if [ -n "$HY_OBFS_PASSWORD" ]; then
        OBFS_BLOCK="\"obfs\": { \"type\": \"salamander\", \"password\": \"$HY_OBFS_PASSWORD\" },"
    fi

    # Bandwidth (only include if non-zero)
    BW_BLOCK=""
    BW_UP=$(echo "$HY_BW_UP" | grep -oE '[0-9]+')
    BW_DOWN=$(echo "$HY_BW_DOWN" | grep -oE '[0-9]+')
    if [ -n "$BW_UP" ] && [ "$BW_UP" != "0" ] && [ -n "$BW_DOWN" ] && [ "$BW_DOWN" != "0" ]; then
        BW_BLOCK="\"up_mbps\": $BW_UP, \"down_mbps\": $BW_DOWN,"
    fi

    cat > "$SINGBOX_CONF" << SINGBOX_EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "redirect",
      "tag": "redirect-in",
      "listen": "0.0.0.0",
      "listen_port": $REDIRECT_PORT
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": $TPROXY_PORT,
      "network": "udp"
    },
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-out",
      "server": "$HY_HOST",
      "server_port": $HY_PORT,
      "password": "$HY_PASSWORD",
      $OBFS_BLOCK
      $BW_BLOCK
      "tls": {
        "enabled": true,
        "insecure": $TLS_INSECURE
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_mark": $SINGBOX_MARK,
    "rules": [
      {
        "inbound": "socks-in",
        "outbound": "hy2-out"
      }
    ],
    "final": "hy2-out"
  }
}
SINGBOX_EOF
}

# ── Stop ─────────────────────────────────────────────────────────

do_stop() {
    log "Stopping hysteria-keenetic..."

    # TCP REDIRECT cleanup (nat table)
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -F HYSTERIA_REDIRECT 2>/dev/null
    iptables -t nat -X HYSTERIA_REDIRECT 2>/dev/null

    # UDP TPROXY cleanup (mangle table)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -p udp -m set --match-set "$IPSET_NAME" dst -j HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -F HYSTERIA_TPROXY 2>/dev/null
    iptables -t mangle -X HYSTERIA_TPROXY 2>/dev/null

    # Policy routing cleanup (for TPROXY)
    ip rule del fwmark "0x$FWMARK" table "$ROUTE_TABLE" 2>/dev/null
    ip route del local default dev lo table "$ROUTE_TABLE" 2>/dev/null

    # Legacy TUN cleanup (from previous version)
    iptables -t mangle -D PREROUTING -i "$LAN_IF" -m set --match-set "$IPSET_NAME" dst -j HYSTERIA 2>/dev/null
    iptables -t mangle -F HYSTERIA 2>/dev/null
    iptables -t mangle -X HYSTERIA 2>/dev/null
    iptables -t nat -D POSTROUTING -o tun0 -j RETURN 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -o tun0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tun0 -o "$LAN_IF" -j ACCEPT 2>/dev/null
    ip route del default dev tun0 table "$ROUTE_TABLE" 2>/dev/null

    # Legacy old TPROXY cleanup (from Hysteria version)
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null

    log "  iptables: redirect/tproxy cleaned"

    # DoH/DoT blocking cleanup
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 853 -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p tcp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set force_dns dst -j DROP 2>/dev/null
    ipset destroy force_dns 2>/dev/null

    # DNS redirect cleanup
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null

    # Legacy redsocks cleanup (from older versions)
    iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp -m set --match-set "$IPSET_NAME" dst -j REDSOCKS 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null
    iptables -D FORWARD -i "$LAN_IF" -p udp --dport 443 -j DROP 2>/dev/null

    log "  iptables: cleaned"

    # dnsmasq
    if [ -f "$DNSMASQ_PID_FILE" ]; then
        kill "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null
        rm -f "$DNSMASQ_PID_FILE"
    fi
    log "  dnsmasq: stopped"

    # ipset (must be after iptables cleanup)
    ipset destroy "$IPSET_NAME" 2>/dev/null
    log "  ipset: destroyed"

    # dnscrypt-proxy
    killall dnscrypt-proxy 2>/dev/null
    log "  dnscrypt-proxy: stopped"

    # Legacy cleanup
    killall redsocks 2>/dev/null
    killall hysteria 2>/dev/null

    # sing-box
    killall sing-box 2>/dev/null
    sleep 1
    log "  sing-box: stopped"

    log "Stopped."
}

# ── Update ───────────────────────────────────────────────────────

do_update() {
    log "Updating domain lists..."
    sh "$UPDATE_SCRIPT"
}

# ── Upgrade ───────────────────────────────────────────────────────

do_upgrade() {
    log "Checking for sing-box updates..."

    CURRENT_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log "Current version: v$CURRENT_VER"

    log "Updating via opkg..."
    opkg update >/dev/null 2>&1
    AVAIL_VER=$(opkg info sing-box-go 2>/dev/null | grep '^Version' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    if [ -z "$AVAIL_VER" ]; then
        log "Error: Could not check latest version"
        return 1
    fi

    log "Available version: v$AVAIL_VER"

    if [ "$CURRENT_VER" = "$AVAIL_VER" ]; then
        log "Already up to date."
        return 0
    fi

    opkg upgrade sing-box-go 2>&1 | while read -r line; do log "  $line"; done

    NEW_VER=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    log "Upgraded to v$NEW_VER"
    log "Restart hysteria-keenetic to use new version"
}

# ── Status ───────────────────────────────────────────────────────

do_status() {
    echo ""
    echo "  hysteria-keenetic status"
    echo "  ========================"
    echo ""

    # Processes
    echo "  Processes"
    echo "  ---------"
    if pidof sing-box >/dev/null 2>&1; then
        echo "  sing-box:  running (PID $(pidof sing-box))"
    else
        echo "  sing-box:  stopped"
    fi
    if pidof dnscrypt-proxy >/dev/null 2>&1; then
        echo "  dnscrypt:  running (PID $(pidof dnscrypt-proxy), port $DNSCRYPT_PORT via SOCKS5)"
    else
        echo "  dnscrypt:  stopped (DNS goes direct)"
    fi
    DNSMASQ_PID=$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)
    if [ -n "$DNSMASQ_PID" ] && [ -d "/proc/$DNSMASQ_PID" ]; then
        echo "  dnsmasq:   running (PID $DNSMASQ_PID, port $DNSMASQ_PORT)"
    else
        echo "  dnsmasq:   stopped"
    fi
    echo ""

    # Routing
    echo "  Traffic routing"
    echo "  ---------------"
    if iptables -t nat -L HYSTERIA_REDIRECT -n >/dev/null 2>&1; then
        REDIR_PKTS=$(iptables -t nat -L HYSTERIA_REDIRECT -n -v 2>&1 | grep "REDIRECT" | awk '{sum+=$1} END {print sum+0}')
        echo "  TCP redirect: active ($REDIR_PKTS packets redirected to :$REDIRECT_PORT)"
    else
        echo "  TCP redirect: not configured"
    fi
    if iptables -t mangle -L HYSTERIA_TPROXY -n >/dev/null 2>&1; then
        TPROXY_PKTS=$(iptables -t mangle -L HYSTERIA_TPROXY -n -v 2>&1 | grep "TPROXY" | awk '{sum+=$1} END {print sum+0}')
        echo "  UDP tproxy:   active ($TPROXY_PKTS packets proxied to :$TPROXY_PORT)"
    else
        echo "  UDP tproxy:   not configured"
    fi
    if ip rule show 2>/dev/null | grep -q "fwmark 0x$FWMARK"; then
        echo "  policy route: active (fwmark 0x$FWMARK -> table $ROUTE_TABLE -> lo)"
    else
        echo "  policy route: not configured"
    fi
    echo ""

    # IPSet
    echo "  IPSet"
    echo "  -----"
    if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        IPCOUNT=$(ipset list "$IPSET_NAME" | tail -n +8 | wc -l)
        echo "  set '$IPSET_NAME': $IPCOUNT IPs loaded"
    else
        echo "  set '$IPSET_NAME': not created"
    fi
    echo ""

    # Domains
    echo "  Domains"
    echo "  -------"
    if [ -f "$BASE_DIR/domains.lst" ]; then
        echo "  domains.lst: $(wc -l < "$BASE_DIR/domains.lst") domains"
        echo "  last updated: $(ls -l "$BASE_DIR/domains.lst" 2>/dev/null | awk '{print $6, $7, $8}')"
    else
        echo "  domains.lst: not found (run: hysteria-keenetic update)"
    fi
    echo ""

    # Services
    echo "  Enabled services"
    echo "  ----------------"
    echo "  $SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*/  /'
    echo ""

    # DNS encryption blocking
    echo "  DNS encryption blocking"
    echo "  -----------------------"
    if iptables -C FORWARD -i "$LAN_IF" -p tcp --dport 853 -j DROP 2>/dev/null; then
        DOH_IPS=$(ipset list force_dns 2>/dev/null | tail -n +8 | wc -l)
        echo "  DoT block: enabled (port 853 dropped)"
        echo "  DoH block: enabled ($DOH_IPS provider IPs blocked)"
    else
        echo "  DoH/DoT block: disabled"
    fi
    echo ""

    # VPN connectivity test
    echo "  VPN test"
    echo "  --------"
    if pidof sing-box >/dev/null 2>&1; then
        if netstat -tlnup 2>/dev/null | grep -q ":1080"; then
            echo "  SOCKS5: listening on port 1080"
        else
            echo "  SOCKS5: NOT listening"
        fi
        if netstat -tlnup 2>/dev/null | grep -q ":$REDIRECT_PORT"; then
            echo "  redirect: listening on port $REDIRECT_PORT"
        else
            echo "  redirect: NOT listening"
        fi
        if netstat -tlnup 2>/dev/null | grep -q ":$TPROXY_PORT"; then
            echo "  tproxy: listening on port $TPROXY_PORT"
        else
            echo "  tproxy: NOT listening"
        fi
    else
        echo "  sing-box: not running"
    fi
    echo ""

    # Cron
    echo "  Auto-update"
    echo "  -----------"
    if crontab -l 2>/dev/null | grep -q hysteria-keenetic; then
        echo "  cron: $(crontab -l 2>/dev/null | grep hysteria-keenetic)"
    else
        echo "  cron: not configured"
    fi
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────

case "$1" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    update)  do_update ;;
    upgrade) do_upgrade ;;
    status)  do_status ;;
    *)
        echo "hysteria-keenetic — selective VPN routing for Keenetic"
        echo ""
        echo "Usage: $0 {start|stop|restart|update|upgrade|status}"
        echo ""
        echo "  start    Start all components"
        echo "  stop     Stop all, clean iptables"
        echo "  restart  Stop + start"
        echo "  update   Re-download domain lists"
        echo "  upgrade  Update sing-box via opkg"
        echo "  status   Show status of all components"
        echo ""
        echo "Config:  $CONFIG"
        echo "Domains: $BASE_DIR/custom-domains.txt"
        exit 1
    ;;
esac

exit 0
