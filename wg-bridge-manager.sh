#!/usr/bin/env bash
# ShadowVPN WG Bridge Manager — separate, named IPv4 WireGuard egress tunnels.
# Does not change the legacy /etc/shadowvpn-wg-bridge or wg-shadow installation.
set -Eeuo pipefail
umask 077
BASE=/etc/shadowvpn-wg-bridges
HOOK=/usr/local/sbin/shadowvpn-wg-bridge-hook

msg(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask(){ local var=$1 prompt=$2 value; read -r -p "$prompt" value || die 'Input cancelled'; printf -v "$var" '%s' "$value"; }
confirm(){ local answer; ask answer "$1 [type YES]: "; [[ $answer == YES ]] || die 'Cancelled: no changes made by this step.'; }
root_os(){ ((EUID==0)) || die 'Run as root.'; [[ -r /etc/os-release ]] || die 'OS unknown'; . /etc/os-release; [[ ${ID:-} == debian && ( ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ) ]] || die 'Debian 12/13 only'; command -v systemctl >/dev/null || die 'systemd required'; }
deps(){ apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 iptables; install -d -m 700 "$BASE" /etc/wireguard; }
valid_ipv4(){ local x a b c d extra; IFS=. read -r a b c d extra <<< "$1"; [[ -z ${extra:-} && ${a:-} =~ ^[0-9]{1,3}$ && ${b:-} =~ ^[0-9]{1,3}$ && ${c:-} =~ ^[0-9]{1,3}$ && ${d:-} =~ ^[0-9]{1,3}$ ]] || return 1; for x in "$a" "$b" "$c" "$d"; do ((10#$x<=255)) || return 1; done; }
valid_key(){ [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
valid_number(){ [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
profile_name(){ [[ $1 =~ ^[a-z][a-z0-9-]{0,9}$ ]] || die 'Name: 1–10 lowercase letters/digits/hyphens, starts with a letter.'; NAME=$1; IF="wg-${NAME}"; P="$BASE/$NAME"; CFG="/etc/wireguard/${IF}.conf"; [[ ${#IF} -le 15 ]] || die 'Interface name too long'; }
assert_free(){ [[ ! -e $P && ! -e $CFG ]] || die "Profile/config $NAME exists, refusing overwrite"; ! ip link show "$IF" &>/dev/null || die "Interface $IF already exists"; }
network_prompt(){ local part; ask part 'Tunnel subnet first THREE octets (e.g. 10.77.251): '; [[ $part =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die 'Invalid three-octet prefix'; valid_ipv4 "$part.1" || die 'Invalid IPv4 prefix'; NET=$part; EXIT_IP=$part.1; ENTRY_IP=$part.2; if ip -4 -o addr show | grep -Fq "$part."; then die 'Possible existing tunnel subnet collision in local addresses'; fi; if ip -4 route show table all | grep -Fq "$part."; then die 'Possible tunnel subnet collision in routes'; fi; for f in "$BASE"/*/params; do [[ -f $f ]] || continue; if grep -Fqx "NET=$part" "$f"; then die 'Tunnel prefix already used by another managed profile'; fi; done; msg "Subnet: ${part}.0/30  exit: $EXIT_IP  entry: $ENTRY_IP"; }
port_prompt(){ ask PORT 'UDP listening port on EXIT (e.g. 51821): '; valid_number "$PORT" 1 65535 || die 'Invalid port'; if [[ ${1:-exit} == exit ]] && ss -H -lun 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$PORT$"; then die "Local UDP port $PORT appears occupied"; fi; }
wan_prompt(){ local detected; detected=$(ip -4 route show default table main | awk 'NR==1 {for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'); [[ -n $detected ]] || die 'No IPv4 default route in main'; ask WAN "Internet-facing interface on EXIT [$detected]: "; WAN=${WAN:-$detected}; [[ $WAN =~ ^[a-zA-Z0-9_.:-]+$ ]] || die 'Invalid interface name'; ip link show "$WAN" &>/dev/null || die 'WAN interface not found'; }
newkeys(){ install -d -m 700 "$P"; wg genkey > "$P/private.key"; wg pubkey < "$P/private.key" > "$P/public.key"; chmod 600 "$P/"*.key; }
write_params(){ local k; : > "$P/params"; chmod 600 "$P/params"; for k in ROLE IF NET EXIT_IP ENTRY_IP PORT WAN RU_PUBLIC TABLE MARK PRIO ENDPOINT; do printf '%s=%q\n' "$k" "${!k:-}" >> "$P/params"; done; }
key_display(){ msg 'PUBLIC key (safe to exchange):'; cat "$P/public.key"; }
create_hook(){ install -d -m 700 "$BASE"; cat > "$HOOK" <<'HOOK_BODY'
#!/usr/bin/env bash
# Dedicated rule owner. Never flushes chains or alters main default route.
set -Eeuo pipefail
umask 077
MODE=${1:?mode}; NAME=${2:?name}; IF_ARG=${3:?interface}
[[ $NAME =~ ^[a-z][a-z0-9-]{0,9}$ ]] || exit 2
P="/etc/shadowvpn-wg-bridges/$NAME"
[[ -f "$P/params" ]] || { echo 'Missing bridge parameters' >&2; exit 2; }
# shellcheck source=/dev/null
. "$P/params"
[[ "$IF_ARG" == "$IF" && "$IF" == "wg-$NAME" ]] || exit 2
comment="shadowvpn-wg-$NAME"
filter_add(){ local chain=$1; shift; iptables -w -C "$chain" "$@" 2>/dev/null || iptables -w -I "$chain" 1 "$@"; }
filter_del(){ local chain=$1; shift; iptables -w -D "$chain" "$@" 2>/dev/null || true; }
nat_add(){ iptables -w -t nat -C POSTROUTING "${nat_rule[@]}" 2>/dev/null || iptables -w -t nat -A POSTROUTING "${nat_rule[@]}"; }
nat_del(){ iptables -w -t nat -D POSTROUTING "${nat_rule[@]}" 2>/dev/null || true; }
if [[ $ROLE == exit ]]; then
  input_rule=(-i "$WAN" -p udp --dport "$PORT" -m comment --comment "$comment" -j ACCEPT)
  if [[ -n ${RU_PUBLIC:-} ]]; then input_rule=(-i "$WAN" -p udp -s "$RU_PUBLIC/32" --dport "$PORT" -m comment --comment "$comment" -j ACCEPT); fi
  out_rule=(-i "$IF" -o "$WAN" -s "$ENTRY_IP/32" -m comment --comment "$comment" -j ACCEPT)
  in_rule=(-i "$WAN" -o "$IF" -d "$ENTRY_IP/32" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$comment" -j ACCEPT)
  nat_rule=(-s "$ENTRY_IP/32" -o "$WAN" -m comment --comment "$comment" -j MASQUERADE)
  case "$MODE" in
    up)
      sysctl -w net.ipv4.ip_forward=1 >/dev/null
      filter_add INPUT "${input_rule[@]}"
      filter_add FORWARD "${out_rule[@]}"
      filter_add FORWARD "${in_rule[@]}"
      nat_add
      ;;
    down)
      nat_del
      filter_del FORWARD "${in_rule[@]}"
      filter_del FORWARD "${out_rule[@]}"
      filter_del INPUT "${input_rule[@]}"
      ;;
    *) exit 2;;
  esac
elif [[ $ROLE == entry ]]; then
  case "$MODE" in
    up)
      ip -4 route replace default dev "$IF" src "$ENTRY_IP" table "$TABLE"
      printf -v mark_hex '0x%x' "$MARK"
      if ! ip -4 rule show | grep -Eq "^${PRIO}:[[:space:]]+from all fwmark ${mark_hex} lookup ${TABLE}([[:space:]]|$)"; then
        ip -4 rule add priority "$PRIO" fwmark "$MARK" lookup "$TABLE"
      fi
      ;;
    down)
      ip -4 rule del priority "$PRIO" fwmark "$MARK" lookup "$TABLE" 2>/dev/null || true
      ip -4 route del default dev "$IF" table "$TABLE" 2>/dev/null || true
      ;;
    *) exit 2;;
  esac
else exit 2; fi
HOOK_BODY
chmod 700 "$HOOK"; bash -n "$HOOK"; }
service(){ systemctl "$@" "wg-quick@$IF.service"; }
init_exit(){ local tmp; ask tmp 'Location name, e.g. estonia, finland, japan: '; profile_name "$tmp"; assert_free; network_prompt; port_prompt; wan_prompt; ask RU_PUBLIC 'ENTRY public IPv4 for restricted UDP allow (blank = allow from any IP): '; [[ -z $RU_PUBLIC ]] || valid_ipv4 "$RU_PUBLIC" || die 'Invalid ENTRY IPv4'; msg "Create EXIT $NAME ($IF), WAN=$WAN, UDP=$PORT. No existing profiles will be changed."; confirm 'Prepare exit profile?'; deps; create_hook; newkeys; ROLE=exit; TABLE=; MARK=; PRIO=; ENDPOINT=; write_params; cat > "$CFG" <<EOF
[Interface]
Address = ${EXIT_IP}/30
ListenPort = ${PORT}
PrivateKey = $(< "$P/private.key")
Table = off
PostUp = ${HOOK} up ${NAME} %i
PostDown = ${HOOK} down ${NAME} %i
EOF
chmod 600 "$CFG"; msg "EXIT $NAME prepared, WG NOT started. Allow inbound UDP $PORT at provider firewall; host rule is added on WG startup."; key_display; msg "Next: on ENTRY choose 'Prepare entry' for the same location; then return here to add its public key."; }
policy_prompt(){ ask TABLE 'Free policy routing table number [178]: '; TABLE=${TABLE:-178}; valid_number "$TABLE" 1 252 || die 'Use an unused table in range 1–252 (excluding 0, 253–255)'; [[ -z $(ip -4 route show table "$TABLE" 2>/dev/null) ]] || die "Table $TABLE not empty"; if ip -4 rule show | grep -Eq "lookup ${TABLE}([[:space:]]|$)"; then die "Table $TABLE referenced by existing rule"; fi; ask MARK 'Unused Xray fwmark decimal [376]: '; MARK=${MARK:-376}; valid_number "$MARK" 1 2147483647 || die 'Invalid mark'; if ip -4 rule show | grep -Eq "fwmark (0x$(printf '%x' "$MARK")|${MARK})(/|[[:space:]]|$)"; then die "Mark $MARK already used in ip rule"; fi; ask PRIO 'Unused rule priority [17800]: '; PRIO=${PRIO:-17800}; valid_number "$PRIO" 1 32765 || die 'Invalid priority'; if ip -4 rule show | grep -Eq "^${PRIO}:"; then die "Priority $PRIO already used"; fi; }
init_entry(){ local tmp PUB; ask tmp 'Location name (same as EXIT): '; profile_name "$tmp"; assert_free; network_prompt; ask ENDPOINT 'EXIT public IPv4: '; valid_ipv4 "$ENDPOINT" || die 'Invalid exit IPv4'; port_prompt entry; ask PUB 'EXIT WG public key: '; valid_key "$PUB" || die 'Invalid public key'; policy_prompt; ROLE=entry; WAN=; RU_PUBLIC=; msg "Prepare ENTRY $NAME, interface $IF, route table $TABLE, mark $MARK, priority $PRIO. Existing routes will NOT be changed now."; confirm 'Prepare entry profile?'; deps; create_hook; newkeys; write_params; cat > "$CFG" <<EOF
[Interface]
Address = ${ENTRY_IP}/30
PrivateKey = $(< "$P/private.key")
Table = off
PostUp = ${HOOK} up ${NAME} %i
PostDown = ${HOOK} down ${NAME} %i

[Peer]
PublicKey = ${PUB}
Endpoint = ${ENDPOINT}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CFG"; msg 'ENTRY prepared, WG NOT started; main default route unchanged.'; key_display; msg 'Next: on EXIT select Register entry peer, then here select Start.'; }
choose_existing(){ local tmp; ask tmp 'Existing managed location name: '; profile_name "$tmp"; [[ -r $P/params && -r $CFG ]] || die 'Managed profile not found'; . "$P/params"; [[ "$IF" == "wg-$NAME" ]] || die 'Inconsistent profile'; }
add_peer(){ local PUB; choose_existing; [[ $ROLE == exit ]] || die 'Register peer on EXIT only'; ! grep -q '^\[Peer\]' "$CFG" || die 'Peer already exists; refusing to append a duplicate'; ask PUB 'ENTRY WG public key: '; valid_key "$PUB" || die 'Invalid public key'; confirm "Add peer for $NAME and start its EXIT interface?"; printf '\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$PUB" "$ENTRY_IP" >> "$CFG"; chmod 600 "$CFG"; if ! service enable --now; then msg 'WireGuard start failed. Inspect journalctl -u wg-quick@'"$IF"; return 1; fi; msg "EXIT $NAME running. On ENTRY select Start and check handshake."; }
start_bridge(){ choose_existing; confirm "Start $NAME ($ROLE) ?"; [[ $ROLE != exit ]] || grep -q '^\[Peer\]' "$CFG" || die 'Register ENTRY peer first'; create_hook; service enable --now; msg 'Main default route:'; ip -4 route show default; status_bridge "$NAME"; }
stop_bridge(){ choose_existing; confirm "Stop only $NAME ($IF)? Selected users will lose this egress."; service disable --now; msg "Stopped $NAME; no other bridge touched."; }
status_bridge(){ local requested=${1:-}; if [[ -n $requested ]]; then profile_name "$requested"; [[ -r $P/params ]] || die "Unknown profile $requested"; . "$P/params"; msg "=== $NAME ($ROLE) / $IF ==="; systemctl is-active "wg-quick@$IF.service" || true; wg show "$IF" 2>/dev/null || true; [[ $ROLE != entry ]] || { ip -4 rule show | grep -E "^${PRIO}:" || true; ip -4 route show table "$TABLE" || true; }; else list_bridges; fi; }
list_bridges(){ local p; msg '=== Managed profiles ==='; for p in "$BASE"/*/params; do [[ -f $p ]] || continue; NAME=$(basename "$(dirname "$p")"); profile_name "$NAME"; . "$p"; printf '%-12s %-6s %-13s %-7s %s\n' "$NAME" "$ROLE" "$IF" "${PORT:-?}" "$(systemctl is-active "wg-quick@$IF.service" 2>/dev/null || true)"; done; if [[ -e /etc/wireguard/wg-shadow.conf ]]; then msg 'Legacy wg-shadow exists (read-only: use original shadowvpn-wg-bridge.sh to administer).'; fi; }
check_bridge(){ choose_existing; msg "=== $NAME connectivity ==="; wg show "$IF" || true; if [[ $ROLE == entry ]]; then msg 'Main route:'; ip -4 route show default; msg 'Marked route:'; ip -4 route get 1.1.1.1 mark "$MARK" || true; msg 'Tunnel peer (ICMP may be filtered):'; ping -c 2 -W 2 -I "$IF" "$EXIT_IP" || true; msg "To test public egress: curl -4 --interface $IF https://api.ipify.org"; msg "Remnawave freedom outbound: sockopt.mark decimal $MARK; route chosen inbound to it."; else msg 'Check provider firewall permits incoming UDP to this VPS; its own firewall may have independent nftables chains.'; fi; }
menu(){ local choice; while :; do printf '\n%s\n' '=== ShadowVPN WireGuard Bridge Manager ===' '1) Prepare new EXIT (country/location VPS)' '2) Prepare new ENTRY (Russia/entry VPS)' '3) Register ENTRY public key on EXIT + start EXIT' '4) Start existing bridge (one location only)' '5) Stop existing bridge (one location only)' '6) List bridge profiles / legacy status' '7) Check one bridge, routes and handshake' '0) Exit'; ask choice 'Choose [0-7]: '; case "$choice" in 1)init_exit;;2)init_entry;;3)add_peer;;4)start_bridge;;5)stop_bridge;;6)list_bridges;;7)check_bridge;;0)exit 0;;*)msg 'Select 0–7';;esac; done; }
root_os
[[ $# == 0 ]] || die 'This release uses an interactive menu: run without arguments.'
menu
