#!/usr/bin/env bash
# ShadowVPN WG Bridge — Debian 12/13, IPv4-only, RU Xray(host) -> DE WireGuard NAT.
set -Eeuo pipefail
umask 077
WG=wg-shadow
CFG="/etc/wireguard/${WG}.conf"
DIR=/etc/shadowvpn-wg-bridge
NETWORK=10.77.250
DE_TUN=${NETWORK}.1
RU_TUN=${NETWORK}.2
WG_PORT=51820
TABLE=177
MARK=0x177
RULE_PRIORITY=17700
fail(){ echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'Run as root.'
[[ -r /etc/os-release ]] || fail 'Cannot identify OS.'
. /etc/os-release
[[ ${ID:-} == debian && ( ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ) ]] || fail 'Designed for Debian 12/13 only.'
[[ $# -eq 1 ]] || fail "Usage: $0 de-init | ru-init | de-peer | ru-up | status"
command -v systemctl >/dev/null || fail 'systemd is required.'
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wireguard-tools iproute2 iptables ca-certificates
  install -d -m 700 "$DIR" /etc/wireguard
}
check_unused(){
  [[ ! -e $CFG ]] || fail "$CFG already exists; refusing to overwrite."
  [[ ! -e $DIR/private.key ]] || fail 'Key already exists; refusing to overwrite.'
  if ip -4 -o addr show | grep -Eq "(^|[[:space:]])${NETWORK}\\."; then
    fail "${NETWORK}.0/24 overlaps an existing interface; choose another subnet in the script."
  fi
}
keygen(){ wg genkey > "$DIR/private.key"; wg pubkey < "$DIR/private.key" > "$DIR/public.key"; chmod 600 "$DIR/private.key"; }
valid_key(){ [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
valid_ipv4(){
  local a b c d rest
  IFS=. read -r a b c d rest <<< "$1"
  [[ -z ${rest:-} && $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] || return 1
  for n in "$a" "$b" "$c" "$d"; do ((10#$n <= 255)) || return 1; done
}
public_ip(){
  ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]\+\).*/\1/p' | head -1
}
wan_if(){ ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}'; }
show_key(){ echo 'PUBLIC KEY (safe to share between your own servers):'; cat "$DIR/public.key"; }
case "$1" in
  de-init)
    check_unused
    echo 'Germany: this installs a dedicated WG interface and scoped NAT; it does not change the default route.'
    read -r -p 'Proceed on GERMAN VPS? Type DE: ' confirm
    [[ $confirm == DE ]] || fail 'Cancelled.'
    WAN=$(wan_if); [[ -n $WAN ]] || fail 'Cannot identify WAN interface.'
    echo "Detected WAN: $WAN"
    install_deps; keygen
    # No peer until de-peer; WG service is started only after public key of RU is known.
    cat > "$CFG" <<EOF
[Interface]
Address = ${DE_TUN}/30
ListenPort = ${WG_PORT}
PrivateKey = $(cat "$DIR/private.key")
Table = off
PostUp = /usr/local/sbin/shadowvpn-wg-de-fw up %i
PostDown = /usr/local/sbin/shadowvpn-wg-de-fw down %i
EOF
    chmod 600 "$CFG"
    printf '%s\n' "$WAN" > "$DIR/wan"
    cat > /usr/local/sbin/shadowvpn-wg-de-fw <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE=${1:?}; IF=${2:?}
[[ $IF == wg-shadow ]] || exit 1
WAN=$(cat /etc/shadowvpn-wg-bridge/wan)
SRC=10.77.250.2/32
rule(){
  local op=$1; shift
  if [[ $op == up ]]; then
    iptables -w -C "$@" 2>/dev/null || iptables -w -A "$@"
  else
    iptables -w -D "$@" 2>/dev/null || true
  fi
}
case $MODE in
  up)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ip route replace 10.77.250.2/32 dev "$IF"
    rule up FORWARD -i "$IF" -o "$WAN" -s "$SRC" -j ACCEPT
    rule up FORWARD -i "$WAN" -o "$IF" -d "$SRC" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    rule up -t nat POSTROUTING -s "$SRC" -o "$WAN" -j MASQUERADE
    ;;
  down)
    rule down -t nat POSTROUTING -s "$SRC" -o "$WAN" -j MASQUERADE
    rule down FORWARD -i "$WAN" -o "$IF" -d "$SRC" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    rule down FORWARD -i "$IF" -o "$WAN" -s "$SRC" -j ACCEPT
    ip route del 10.77.250.2/32 dev "$IF" 2>/dev/null || true
    ;;
  *) exit 1;;
esac
EOF
    chmod 700 /usr/local/sbin/shadowvpn-wg-de-fw
    cat > /etc/sysctl.d/90-shadowvpn-wg-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "DE init done. WAN=$WAN; WG UDP port=$WG_PORT. Allow incoming UDP $WG_PORT in provider firewall if needed."
    show_key
    echo 'Next: run ru-init on Russia, then de-peer on Germany, then ru-up on Russia.'
    ;;
  ru-init)
    check_unused
    echo 'Russia: wg-quick Table=off. Only sockets explicitly marked by Xray can use the dedicated routing table.'
    read -r -p 'Proceed on RUSSIAN VPS? Type RU: ' confirm
    [[ $confirm == RU ]] || fail 'Cancelled.'
    read -r -p 'German VPS public IPv4: ' DE_IP
    valid_ipv4 "$DE_IP" || fail 'Invalid IPv4.'
    read -r -p 'German WG public key (from de-init): ' DE_PUB
    valid_key "$DE_PUB" || fail 'Invalid WireGuard public key.'
    # Ensure no overlapping assigned address before installing.
    ip -4 -o addr show | grep -Eq "(^|[[:space:]])${NETWORK}\\." && fail 'Tunnel subnet overlaps existing interface.' || true
    install_deps; keygen
    cat > "$CFG" <<EOF
[Interface]
Address = ${RU_TUN}/30
PrivateKey = $(cat "$DIR/private.key")
Table = off
PostUp = /usr/local/sbin/shadowvpn-wg-ru-route up %i
PostDown = /usr/local/sbin/shadowvpn-wg-ru-route down %i

[Peer]
PublicKey = $DE_PUB
Endpoint = ${DE_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$CFG"
    cat > /usr/local/sbin/shadowvpn-wg-ru-route <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE=${1:?}; IF=${2:?}
[[ $IF == wg-shadow ]] || exit 1
MARK=0x177; TABLE=177; PRIORITY=17700
case $MODE in
  up)
    ip route replace default dev "$IF" src 10.77.250.2 table "$TABLE"
    ip rule show | grep -qE '^17700:.*fwmark 0x177.*lookup 177' || ip rule add priority "$PRIORITY" fwmark "$MARK" lookup "$TABLE"
    ip -4 route flush cache
    ;;
  down)
    ip rule del priority "$PRIORITY" fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
    ip route flush table "$TABLE" 2>/dev/null || true
    ip -4 route flush cache
    ;;
  *) exit 1;;
esac
EOF
    chmod 700 /usr/local/sbin/shadowvpn-wg-ru-route
    echo 'RU initialized but WG NOT STARTED. Public key below; use it with de-peer on Germany.'
    show_key
    ;;
  de-peer)
    [[ -f $CFG && -f $DIR/public.key ]] || fail 'Run de-init first.'
    grep -q '^\[Peer\]' "$CFG" && fail 'A peer already exists. No automatic overwrite.'
    read -r -p 'Russian WG public key (from ru-init): ' RU_PUB
    valid_key "$RU_PUB" || fail 'Invalid WireGuard public key.'
    cat >> "$CFG" <<EOF

[Peer]
PublicKey = $RU_PUB
AllowedIPs = ${RU_TUN}/32
EOF
    systemctl enable --now "wg-quick@${WG}.service"
    wg show "$WG"
    echo 'Germany WG is running; now run ru-up on Russia.'
    ;;
  ru-up)
    [[ -f $CFG ]] || fail 'Run ru-init first.'
    systemctl enable --now "wg-quick@${WG}.service"
    echo 'Russia WG started. Main route (should still be via original WAN):'
    ip -4 route show default
    echo 'Marked route (should be via wg-shadow):'
    ip -4 route get 1.1.1.1 mark "$MARK"
    echo 'Handshake may take a few seconds; check: wg show wg-shadow'
    echo 'DO NOT route all Xray traffic yet. First validate the tunnel and add an isolated inbound routing rule.'
    ;;
  status)
    ip -4 route show default
    ip -4 rule show
    ip -4 route show table "$TABLE" || true
    wg show "$WG" || true
    ;;
  *) fail 'Unknown mode.';;
esac
