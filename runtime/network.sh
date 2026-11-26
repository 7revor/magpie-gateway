#!/bin/sh
set -eu

lan=lan0
gateway=10.77.0.2
port=7893
mark=0x177

case "${1:-}" in
  gateway)
    # 网关不做内核转发，仅把 LAN 上的 TCP/UDP 交给本地 Mihomo。
    iptables -w -P FORWARD DROP
    ip -4 route replace local 0.0.0.0/0 dev lo table 177
    ip -4 rule add pref 177 fwmark "$mark" lookup 177
    iptables -w -t mangle -N MAGPIE_PROXY
    iptables -w -t mangle -A MAGPIE_PROXY -m addrtype ! --dst-type UNICAST -j RETURN
    for proto in tcp udp; do
      iptables -w -t mangle -A MAGPIE_PROXY -p "$proto" -j TPROXY \
        --on-port "$port" --tproxy-mark "$mark/0xffffffff"
      # 不允许直接连接 TPROXY 监听端口，尤其是来自 WAN 的流量。
      iptables -w -A INPUT -p "$proto" --dport "$port" -m mark ! --mark "$mark" -j DROP
    done
    iptables -w -t mangle -A PREROUTING -i "$lan" -j MAGPIE_PROXY
    exec /mihomo -d /var/lib/mihomo -f /etc/mihomo/config.yaml
    ;;
  client)
    ip -4 route replace default via "$gateway" dev "$lan"
    # 阻止应用绕过 resolv.conf 直接请求 Docker 内置 DNS（DNAT 之前）。
    iptables -w -t raw -C OUTPUT -d 127.0.0.11/32 -j DROP 2>/dev/null ||
      iptables -w -t raw -I OUTPUT -d 127.0.0.11/32 -j DROP
    exec sleep infinity
    ;;
  health-gateway)
    ss -H -lnt "sport = :$port" | grep -q .
    ss -H -lnu "sport = :$port" | grep -q .
    ;;
  health-client)
    ip -4 route show default dev "$lan" | grep -Fq "via $gateway"
    iptables -w -t raw -C OUTPUT -d 127.0.0.11/32 -j DROP
    ;;
  *)
    echo '用法：network gateway|client|health-gateway|health-client' >&2
    exit 2
    ;;
esac
