#!/usr/bin/env bash
# ShadowVPN WG Bridge: Debian 12/13; IPv4; Xray(host network) RU -> WireGuard -> DE NAT.
set -Eeuo pipefail
umask 077

WG=wg-shadow
DIR=/etc/shadowvpn-wg-bridge
CFG="/etc/wireguard/${WG}.conf"
DE_FW=/usr/local/sbin/shadowvpn-wg-de-fw
RU_ROUTE=/usr/local/sbin/shadowvpn-wg-ru-route
DE_FW_UNIT=shadowvpn-wg-de-firewall.service
NET=10.77.250
DE_TUN=$NET.1
RU_TUN=$NET.2
PORT=51820
TABLE=177
MARK=0x177
PRIO=17700

say(){ printf '%s\n' "$*"; }
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root(){ (( EUID == 0 )) || fail 'Run as root.'; }
require_debian(){
  [[ -r /etc/os-release ]] || fail 'Cannot identify OS.'
  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == debian && ( ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ) ]] || fail 'Only Debian 12/13 is supported.'
  command -v systemctl >/dev/null || fail 'systemd is required.'
}
confirm_role(){
  local value
  read -r -p "This changes networking on the $1 VPS. Type $1 to continue: " value
  [[ $value == "$1" ]] || fail 'Cancelled.'
}
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y wireguard-tools iproute2 iptables ca-certificates
  install -d -m 700 "$DIR" /etc/wireguard
}
wan_if(){ ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'; }
valid_key(){ [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
valid_ip(){
  local a b c d more n
  IFS=. read -r a b c d more <<< "$1"
  [[ -z ${more:-} && $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] || return 1
  for n in "$a" "$b" "$c" "$d"; do (( 10#$n <= 255 )) || return 1; done
}
no_collision(){
  [[ ! -e $CFG && ! -e $DIR/private.key ]] || fail "Existing $CFG or key; refusing to overwrite."
  ! ip -4 -o addr show | grep -Eq "[[:space:]]${NET}\\." || fail "Tunnel subnet ${NET}.0/30 is already in use."
  ! ip -4 route show table all | grep -Eq "(^|[[:space:]])${NET}\\." || fail "Tunnel subnet ${NET}.0/30 already appears in routes."
  ! ip link show "$WG" &>/dev/null || fail "Interface $WG already exists."
}
new_keys(){
  wg genkey > "$DIR/private.key"
  wg pubkey < "$DIR/private.key" > "$DIR/public.key"
  chmod 600 "$DIR/private.key"
}
show_pub(){ say 'Public key (safe to exchange with your own servers):'; cat "$DIR/public.key"; }
install_de_firewall(){
  cat > "$DE_FW" <<'FW'
#!/usr/bin/env bash
set -Eeuo pipefail
MODE=${1:?mode required}; IF=${2:-wg-shadow}
[[ $IF == wg-shadow ]] || { echo 'Unexpected interface' >&2; exit 1; }
WAN=$(< /etc/shadowvpn-wg-bridge/wan)
[[ $WAN =~ ^[a-zA-Z0-9_.:-]+$ ]] || { echo 'Invalid WAN interface' >&2; exit 1; }
SRC=10.77.250.2/32
# iptables-nft is supported. These rules never flush or replace existing chains.
input_rule=(-i "$WAN" -p udp --dport 51820 -m comment --comment shadowvpn-wg-bridge -j ACCEPT)
forward_out=(-i "$IF" -o "$WAN" -s "$SRC" -m comment --comment shadowvpn-wg-bridge -j ACCEPT)
forward_in=(-i "$WAN" -o "$IF" -d "$SRC" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment shadowvpn-wg-bridge -j ACCEPT)
nat_rule=(-s "$SRC" -o "$WAN" -m comment --comment shadowvpn-wg-bridge -j MASQUERADE)
add_filter(){ local chain=$1; shift; iptables -w -C "$chain" "$@" 2>/dev/null || iptables -w -I "$chain" 1 "$@"; }
del_filter(){ local chain=$1; shift; iptables -w -D "$chain" "$@" 2>/dev/null || true; }
add_nat(){ iptables -w -t nat -C POSTROUTING "${nat_rule[@]}" 2>/dev/null || iptables -w -t nat -A POSTROUTING "${nat_rule[@]}"; }
del_nat(){ iptables -w -t nat -D POSTROUTING "${nat_rule[@]}" 2>/dev/null || true; }
case "$MODE" in
  allow) add_filter INPUT "${input_rule[@]}" ;;
  unallow) del_filter INPUT "${input_rule[@]}" ;;
  up)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    add_filter INPUT "${input_rule[@]}"
    add_filter FORWARD "${forward_out[@]}"
    add_filter FORWARD "${forward_in[@]}"
    add_nat
    ;;
  down)
    del_nat
    del_filter FORWARD "${forward_in[@]}"
    del_filter FORWARD "${forward_out[@]}"
    # INPUT is owned by the separate persistent firewall service.
    ;;
  *) echo "Unknown firewall mode: $MODE" >&2; exit 2 ;;
esac
FW
  chmod 700 "$DE_FW"
  bash -n "$DE_FW"
  cat > "/etc/systemd/system/$DE_FW_UNIT" <<EOF
[Unit]
Description=ShadowVPN WireGuard inbound UDP firewall rule
After=network-online.target
Before=wg-quick@${WG}.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${DE_FW} allow ${WG}
ExecStop=${DE_FW} unallow ${WG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$DE_FW_UNIT"
  # Persist global forwarding; no default routes are modified.
  printf 'net.ipv4.ip_forward = 1\n' > /etc/sysctl.d/90-shadowvpn-wg-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}
install_ru_route(){
  cat > "$RU_ROUTE" <<'ROUTE'
#!/usr/bin/env bash
set -Eeuo pipefail
MODE=${1:?mode required}; IF=${2:?interface required}
[[ $IF == wg-shadow ]] || exit 2
TABLE=177; MARK=0x177; PRIO=17700
case "$MODE" in
  up)
    ip -4 route replace default dev "$IF" src 10.77.250.2 table "$TABLE"
    if ! ip -4 rule show | grep -Eq '^17700:[[:space:]]+from all fwmark 0x177 lookup 177([[:space:]]|$)'; then
      ip -4 rule add priority "$PRIO" fwmark "$MARK" lookup "$TABLE"
    fi
    ;;
  down)
    ip -4 rule del priority "$PRIO" fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
    ip -4 route del default dev "$IF" table "$TABLE" 2>/dev/null || true
    ;;
  *) exit 2 ;;
esac
ROUTE
  chmod 700 "$RU_ROUTE"
  bash -n "$RU_ROUTE"
}
check_ru_policy(){
  ! ip -4 rule show | grep -Eq "^${PRIO}:" || fail "IP rule priority $PRIO already used."
  [[ -z $(ip -4 route show table "$TABLE") ]] || fail "Routing table $TABLE already contains routes."
}
require_root
require_debian
[[ $# == 1 ]] || fail "Usage: $0 de-init | ru-init | de-peer | de-repair | ru-up | status"
case "$1" in
  de-init)
    no_collision
    confirm_role DE
    WAN=$(wan_if); [[ -n $WAN ]] || fail 'Could not detect external interface.'
    install_deps
    new_keys
    printf '%s\n' "$WAN" > "$DIR/wan"
    install_de_firewall
    cat > "$CFG" <<EOF
[Interface]
Address = ${DE_TUN}/30
ListenPort = ${PORT}
PrivateKey = $(< "$DIR/private.key")
Table = off
PostUp = ${DE_FW} up %i
PostDown = ${DE_FW} down %i
EOF
    chmod 600 "$CFG"
    say "Germany initialized: WAN=$WAN, UDP=$PORT, no default-route change."
    say 'Check provider firewall permits inbound UDP 51820 from the Russian VPS.'
    show_pub
    say 'Next: ru-init on Russia, then de-peer on Germany, then ru-up on Russia.'
    ;;
  ru-init)
    no_collision
    check_ru_policy
    confirm_role RU
    read -r -p 'German VPS public IPv4: ' DE_IP
    valid_ip "$DE_IP" || fail 'Invalid IPv4 address.'
    read -r -p 'German WireGuard public key: ' DE_PUB
    valid_key "$DE_PUB" || fail 'Invalid public key.'
    install_deps
    new_keys
    cat > "$CFG" <<EOF
[Interface]
Address = ${RU_TUN}/30
PrivateKey = $(< "$DIR/private.key")
Table = off
PostUp = ${RU_ROUTE} up %i
PostDown = ${RU_ROUTE} down %i

[Peer]
PublicKey = ${DE_PUB}
Endpoint = ${DE_IP}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$CFG"
    install_ru_route
    say 'Russia initialized but WireGuard NOT STARTED.'
    show_pub
    say 'Next: de-peer on Germany, then ru-up on Russia.'
    ;;
  de-peer)
    [[ -f $CFG && -f $DIR/public.key && -f $DIR/wan ]] || fail 'Run de-init first.'
    ! grep -q '^\[Peer\]' "$CFG" || fail 'Peer already configured; refusing overwrite.'
    confirm_role DE
    read -r -p 'Russian WireGuard public key: ' RU_PUB
    valid_key "$RU_PUB" || fail 'Invalid public key.'
    cat >> "$CFG" <<EOF

[Peer]
PublicKey = ${RU_PUB}
AllowedIPs = ${RU_TUN}/32
EOF
    # Even on an existing host, make sure the dedicated INPUT rule is persistent.
    [[ -x $DE_FW ]] || fail "Missing $DE_FW; use de-repair first."
    systemctl enable --now "$DE_FW_UNIT"
    systemctl enable --now "wg-quick@${WG}.service"
    wg show "$WG"
    say 'Germany running. Next: ru-up on Russia.'
    ;;
  de-repair)
    # Upgrade only this project's firewall helper; preserve WG keys, config and peers.
    [[ -f $CFG && -f $DIR/wan && -f $DIR/private.key ]] || fail 'Existing ShadowVPN DE setup not found.'
    grep -Fq "PostUp = ${DE_FW} up %i" "$CFG" || fail 'Unexpected WG config; refusing to replace firewall helper.'
    grep -Eq '^Address = 10\.77\.250\.1/30$' "$CFG" || fail 'Unexpected tunnel address.'
    confirm_role DE
    install_de_firewall
    if systemctl is-active --quiet "wg-quick@${WG}.service"; then
      "$DE_FW" up "$WG"  # Apply the fixed NAT/FORWARD rules without restarting an active tunnel.
    fi
    say 'German firewall helper upgraded; WG configuration and keys unchanged.'
    say 'Verify: wg show wg-shadow; systemctl status shadowvpn-wg-de-firewall --no-pager'
    ;;
  ru-up)
    [[ -f $CFG && -x $RU_ROUTE ]] || fail 'Run ru-init first.'
    confirm_role RU
    systemctl enable --now "wg-quick@${WG}.service"
    say 'Main IPv4 route (must still use normal WAN):'; ip -4 route show default
    say 'Marked IPv4 route (must use wg-shadow):'; ip -4 route get 1.1.1.1 mark "$MARK"
    say 'Check wg show wg-shadow and ping -c 4 -I wg-shadow 10.77.250.1 before changing Xray.'
    ;;
  status)
    systemctl is-active "wg-quick@${WG}.service" || true
    ip -4 route show default
    ip -4 rule show
    ip -4 route show table "$TABLE" || true
    wg show "$WG" || true
    ;;
  *) fail 'Unknown mode.' ;;
esac
