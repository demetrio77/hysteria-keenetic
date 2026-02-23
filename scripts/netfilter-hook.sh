#!/bin/sh
# Keenetic NDM netfilter hook for hysteria-keenetic
# Placed in /opt/etc/ndm/netfilter.d/ to restore iptables rules
# when Keenetic rebuilds its firewall (interface changes, VPN up/down, etc.)
#
# NDM calls this with: $type = "iptables"|"ip6tables", $table = "nat"|"mangle"|"filter"

[ "$type" = "iptables" ] || exit 0
[ "$table" = "nat" ] || [ "$table" = "mangle" ] || [ "$table" = "filter" ] || exit 0

/opt/etc/hysteria-keenetic/scripts/manage.sh firewall-reload
