# hysteria-keenetic

[English](README.md) | [Русский](README.ru.md)

Selective traffic routing through VPN for **Keenetic routers** with Entware. Only traffic to blocked domains goes through the VPN — everything else stays direct.

Uses [sing-box](https://sing-box.sagernet.org/) with [Hysteria 2](https://v2.hysteria.network/) (QUIC-based) outbound for DPI-resistant tunneling. Built for Russian ISPs but works for any geo-restriction scenario.

## How it works

```
LAN device
    │
    ▼  DNS query (port 53)
iptables PREROUTING ──► REDIRECT to dnsmasq (:5300)
    │
    ▼
dnsmasq (:5300)
    ├── resolves via dnscrypt-proxy (:5301) ──► SOCKS5 ──► VPS ──► DNS
    ├── domain in blocklist? → adds IP to ipset "unblock"
    └── returns response to client
    │
    ▼  TCP/UDP connection
iptables PREROUTING ──► checks ipset "unblock"
    ├── TCP: nat REDIRECT ──► sing-box (:2500) ──► Hysteria 2 ──► VPS
    ├── UDP: mangle TPROXY ──► sing-box (:2501) ──► Hysteria 2 ──► VPS
    └── IP not in set → direct connection
```

Why this design:
- **REDIRECT for TCP, TPROXY for UDP.** Kernel 4.9 (Keenetic) has a TPROXY bug with long-lived TCP connections — breaks SSE streaming, Claude Code, etc. UDP TPROXY works fine, so QUIC goes through it as-is.
- **DNS resolves through VPS.** CDNs (YouTube, Google) return IPs closest to whoever resolves. Resolving locally gives you IPs optimized for your ISP, but traffic goes through VPS in another country. Result — slow. So DNS goes through VPS too.
- **Dynamic ipset.** IPs are added at DNS query time. No static lists going stale.

## Requirements

- Keenetic router with [Entware](https://github.com/Entware/Entware/wiki)
- VPS (Linux, 512MB RAM minimum, 1 core is enough) with UDP port 443 open
- SSH access to the router

### Netfilter modules (required)

Without this, ipset and traffic redirection won't work.

Keenetic web UI → **Management** → **System settings** → **Change component set** → **OPKG packages** → **Netfilter kernel modules** → enable → reboot router.

## Quick start

### 1. Hysteria 2 server on VPS

Two options: with a domain or without.

<details>
<summary><b>Option A: With a domain (Let's Encrypt)</b></summary>

```yaml
# /etc/hysteria/config.yaml
listen: :443

acme:
  domains:
    - your-domain.com
  email: your@email.com

auth:
  type: password
  password: your-strong-password

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
```
</details>

<details>
<summary><b>Option B: No domain (self-signed certificate)</b></summary>

```bash
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" -days 36500
chmod 644 /etc/hysteria/server.key
```

```yaml
# /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: your-strong-password

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
```
</details>

Install and start:
```bash
bash <(curl -fsSL https://get.hy2.sh/)
systemctl enable --now hysteria-server
```

### 2. Router

```bash
ssh root@your-router-ip
cd /tmp
curl -L -o hk.tar.gz https://github.com/dnikonov/hysteria-keenetic/archive/main.tar.gz
tar xzf hk.tar.gz
cd hysteria-keenetic-main

cp config.example config
vi config
# HY_SERVER=your-vps-ip:443   (required)
# HY_PASSWORD=password          (required)
# HY_TLS_INSECURE=1             (if using self-signed cert)

sh install.sh
hysteria-keenetic start
```

### 3. Verify

```bash
hysteria-keenetic status
```

Open a blocked site from any device on your network. No client-side configuration needed — it's fully transparent.

## Configuration

File: `/opt/etc/hysteria-keenetic/config`

### Main

| Parameter | Description | Example |
|-----------|-------------|---------|
| `HY_SERVER` | Server address | `1.2.3.4:443` |
| `HY_PASSWORD` | Server password | |
| `SERVICES` | Comma-separated services | `Youtube,Google,Openai` |

### Hysteria 2

| Parameter | Default | Description |
|-----------|---------|-------------|
| `HY_BW_UP` | `50 mbps` | Upload speed (Brutal CC). `0` = BBR |
| `HY_BW_DOWN` | `100 mbps` | Download speed (Brutal CC). `0` = BBR |
| `HY_TLS_INSECURE` | `0` | `1` for self-signed server certs |
| `HY_OBFS_PASSWORD` | *(empty)* | Salamander obfuscation (see below) |
| `HY_QUIC_TUNING` | `0` | `1` for large QUIC buffers on fast links |

### Other

| Parameter | Default | Description |
|-----------|---------|-------------|
| `FORCE_DNS` | `1` | Block DoH/DoT to prevent DNS bypass |
| `LAN_IF` | `br0` | LAN interface |
| `DNSMASQ_PORT` | `5300` | dnsmasq port |
| `FWMARK` | `2` | Packet mark for UDP policy routing |
| `ROUTE_TABLE` | `101` | Routing table |
| `CRON_SCHEDULE` | `0 4 * * *` | Auto-update schedule for domain lists |

### Services

Most lists come from [DomainMapper](https://github.com/Ground-Zerro/DomainMapper): Youtube, Google, Facebook, Tik-Tok, Twitter, Openai, Instagram, Discord, Twitch, Telegram, Netflix, Bing, Adobe, Apple, Jetbrains, Xbox, Windsurf, Roblox, Zscaler, Torrent Trackers, Online movie theaters, Search engines, Github Copilot.

Plus [Antifilter community edition](https://community.antifilter.download/), [ITDog Inside/Outside](https://github.com/itdoginfo/allow-domains), [WhatsApp](https://github.com/HybridNetworks/whatsapp-cidr).

### Custom domains and IPs

File `custom-domains.txt` (make sure `custom` is in `SERVICES`):

```
# Domains — resolved by dnsmasq, IPs added to ipset dynamically
my-blocked-site.com
another-site.io

# IP/CIDR — added to ipset directly
# For services with dedicated IP ranges that can't be caught via DNS
160.79.104.0/23
```

```bash
hysteria-keenetic update
```

## Commands

```bash
hysteria-keenetic start      # Start all components
hysteria-keenetic stop       # Stop everything, clean iptables
hysteria-keenetic restart    # Restart
hysteria-keenetic update     # Update domain lists
hysteria-keenetic upgrade    # Upgrade sing-box via opkg
hysteria-keenetic status     # Show component status
```

## Additional setup

### Obfuscation (Salamander)

Needed if your ISP throttles or blocks QUIC via DPI. Symptoms: frequent `client disconnected` in Hysteria server logs, connections drop after a few seconds of active use, speeds fluctuate wildly or drop to zero.

Add to **server** config:
```yaml
obfs:
  type: salamander
  salamander:
    password: your-obfs-password
```

And on the **router** in config:
```
HY_OBFS_PASSWORD=your-obfs-password
```

Passwords must match. QUIC traffic will look like random UDP after this.

### Large QUIC buffers

For links above 50 Mbps, add to server config:

```yaml
quicConfig:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
```

And set `HY_QUIC_TUNING=1` on the router.

### DoH/DoT blocking

With `FORCE_DNS=1` (default), DNS-over-TLS (port 853) and DNS-over-HTTPS to known providers (Google, Cloudflare, Quad9, OpenDNS, AdGuard, CleanBrowsing) are blocked from LAN. Without this, browsers and devices with hardcoded DoH will resolve outside our dnsmasq and the ipset won't get populated.

### Hardware NAT (FASTNAT)

Keenetic uses hardware NAT acceleration which can bypass iptables for established connections. On startup, `conntrack -F` flushes the connection tracking table so all connections re-establish through the new rules. If something doesn't work after starting — try `conntrack -F` manually and clear DNS cache on the client.

### DNS warmup

On startup, popular domains from enabled services are resolved upfront so the ipset is populated before clients start hitting cached DNS records.

### Keenetic firmware updates

Entware lives on a USB drive / opt partition — firmware updates don't touch it. But if the router gets factory-reset, you'll need to re-enable Netfilter modules.

## Troubleshooting

**"No chain/target/match by that name"** — Netfilter modules not enabled. See above.

**Video is slow** — check `hysteria-keenetic status`. If VPS is far away, try closer (Amsterdam, Frankfurt instead of London). Enable obfuscation if your ISP kills QUIC. On fast links try `HY_QUIC_TUNING=1`.

**Site doesn't load through VPN** — add it to `custom-domains.txt` and run `hysteria-keenetic update`. For services with dedicated IPs (not discoverable via DNS) — add CIDR entries.

**"HY_SERVER is not configured"** — `vi /opt/etc/hysteria-keenetic/config`

**Diagnostics:**
```bash
# DNS via dnsmasq
dig youtube.com @127.0.0.1 -p 5300

# IP in ipset?
ipset test unblock 142.250.74.14

# VPN working?
curl --socks5 127.0.0.1:1080 https://ifconfig.me

# Logs
logread | grep hysteria-keenetic
logread | grep hy-update
```

## Uninstall

```bash
sh /opt/etc/hysteria-keenetic/uninstall.sh
```

## Links

- [sing-box](https://sing-box.sagernet.org/) — proxy platform
- [Hysteria 2](https://v2.hysteria.network/) — QUIC-based VPN
- [DomainMapper](https://github.com/Ground-Zerro/DomainMapper), [antifilter.download](https://community.antifilter.download/), [ITDog](https://github.com/itdoginfo/allow-domains) — domain lists
- [DNSCrypt](https://github.com/DNSCrypt/dnscrypt-proxy) — DNS proxy

## License

[MIT](LICENSE)