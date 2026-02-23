#!/bin/sh
# Keenetic NDM netfilter hook for hysteria-keenetic
# Placed in /opt/etc/ndm/netfilter.d/ to restore iptables rules
# when Keenetic rebuilds its firewall (interface changes, VPN up/down, etc.)

[ "$type" = "ip4" ] || exit 0

/opt/etc/hysteria-keenetic/scripts/manage.sh firewall-reload
