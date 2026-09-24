# ShadowVPN WG Bridge

A small, self-hosted Bash installer for a **selective Russia → Germany egress bridge**:

```text
Selected VPN client
       │  Xray inbound (RU)
       ▼
RU: RemnaNode / Xray ── WireGuard (UDP/51820) ──► DE: WireGuard ── NAT ──► Internet
       │                                              
       └─ SSH, Remnawave management and other inbounds stay on their existing routes
```

The German VPS provides the public egress IPv4 address. The Russian VPS keeps its existing default route. The script creates a separate routing table (`177`) and an IP rule for packets explicitly marked `0x177` (decimal `375`). **It does not automatically route any Xray inbound:** you must configure the outbound and inbound routing in Remnawave after validating the tunnel.

> [!IMPORTANT]
> This project changes firewall and routing settings on two real servers. Test on staging or during a maintenance window, keep provider-console access available, and review the script before running it as root. It is not a guarantee that SSH or your existing network stack cannot be disrupted. Back up existing firewall and Remnawave config first.

## What it does

- Installs `wireguard-tools`, `iproute2`, `iptables` and creates one dedicated `wg-shadow` interface on each VPS.
- Generates separate WireGuard key pairs; **private keys remain on their respective servers**.
- Germany: configures the peer, a narrowly scoped IPv4 forwarding/NAT rule for `10.77.250.2/32`, and an explicitly scoped incoming UDP/51820 allow rule. A separate enabled systemd unit restores that inbound rule on boot.
- Russia: uses `Table = off` and routes **only fwmark `0x177`** through table `177` to `wg-shadow`; it does not replace the main default route.
- Does not change RemnaNode/Xray configs, Docker configuration, remote provider firewalls, SSH settings or any IPv6 routes.

### Scope and limitations

| Setting | Value |
| --- | --- |
| Supported OS | Debian 12/13 with systemd |
| IP version | IPv4 only |
| Interface | `wg-shadow` |
| WG subnet | `10.77.250.0/30`: DE `.1`, RU `.2` |
| WG listen port | UDP `51820` on DE |
| Routing table / mark / rule priority | `177` / `0x177` (`375`) / `17700` |
| Topology | One RU peer and one DE peer; DE performs IPv4 NAT |
| Xray topology | Designed for RemnaNode / Xray using Docker `network_mode: host` |

The address range, interface name, table, mark and rule priority are currently constants in the script. **Check for conflicts before installing.** There is no automatic multi-bridge allocation, IPv6 forwarding, key rotation, cloud-firewall automation, high availability or continuous health monitoring.

## Prerequisites

1. Two VPS hosts (RU and DE), root privileges, Debian 12 or 13, and provider-console/serial-console access if SSH fails.
2. RemnaNode/Xray running on RU in **host network mode**. The DE server may also run RemnaNode; the WG configuration is independent of its Xray process.
3. Ability to permit **incoming UDP/51820 from the RU public IP** in the DE provider firewall. The installer adds an `iptables` INPUT rule, but a provider firewall, other nftables base chains, CrowdSec, or other firewall managers can still deny packets.
4. An existing IPv4 default route through the normal WAN interface on both servers. Keep your control-plane/SSH access separate from the selected data-plane routing.
5. No existing `/etc/wireguard/wg-shadow.conf`, `wg-shadow` interface, `10.77.250.0/30` route, or conflicting RU routing table `177` / rule priority `17700`.

### Back up before installation

Run **on both hosts**:

```bash
mkdir -p /root/wg-bridge-backup
ip -4 route show table all > /root/wg-bridge-backup/routes.txt
ip -4 rule show > /root/wg-bridge-backup/rules.txt
iptables-save > /root/wg-bridge-backup/iptables-save.txt
nft -a list ruleset > /root/wg-bridge-backup/nft-ruleset.txt
```

If you operate a provider firewall, keep a record of its current rules too. Do **not** restore an old complete firewall dump blindly on a live Docker/RemnaNode host.

## Installation

Use the GitHub repository you control, review the code, and pin the commit for deployments rather than piping a mutable remote script directly into `bash`.

```bash
git clone https://github.com/HikaruApps/wg-bridge.git
cd wg-bridge
bash -n shadowvpn-wg-bridge.sh
chmod 700 shadowvpn-wg-bridge.sh
```

### 1. Prepare Germany

On the **German** VPS:

```bash
sudo ./shadowvpn-wg-bridge.sh de-init
```

Confirm `DE`. The installer prepares the keys and configuration and enables a dedicated rule allowing UDP/51820 on the detected WAN; **it does not start WireGuard until the RU public key has been registered**. Save the printed **German public key** and make sure the provider firewall allows RU → DE UDP/51820.

### 2. Prepare Russia

On the **Russian** VPS:

```bash
sudo ./shadowvpn-wg-bridge.sh ru-init
```

Confirm `RU`, then enter the DE public IPv4 and the **German WireGuard public key**. Save the printed **Russian public key**. This step does **not** start WireGuard or change the default route.

### 3. Register the Russian peer on Germany

On **Germany**:

```bash
sudo ./shadowvpn-wg-bridge.sh de-peer
```

Confirm `DE`, paste the **Russian public key**, and check that `wg-quick@wg-shadow.service` starts. The peer config is single-peer by design: rerunning `de-peer` will refuse to append a second peer.

### 4. Bring up Russia

On **Russia**:

```bash
sudo ./shadowvpn-wg-bridge.sh ru-up
```

Confirm `RU`. Verify that the **main default route still uses the original WAN**, and that only the route lookup for mark `0x177` points to `wg-shadow`.

### 5. Validate before touching Xray

On **Russia**:

```bash
wg show wg-shadow
ping -c 4 -I wg-shadow 10.77.250.1
ip -4 route show default
ip -4 route get 1.1.1.1 mark 0x177
ip -4 route get 1.1.1.1
```

Expected: a recent WireGuard handshake, received **and** sent bytes, replies from `10.77.250.1`, a marked route through `wg-shadow`, and an unmarked route through the normal WAN. A successful handshake alone **does not** prove that NAT or the eventual Xray egress works.

Check egress from the selected Xray inbound in the next step (e.g. with an IP-echo site). The selected inbound should show the DE public IPv4; a normal RU inbound and SSH should retain their current behavior.

## Remnawave / Xray: route only the chosen inbound

WireGuard is a transport here, not an Xray outbound protocol. Add a **`freedom` outbound** in your RU Remnawave Config Profile, and set `sockopt.mark` to decimal `375` (`0x177`). Then route only the desired inbound tag to that outbound.

Example **outbound object** (merge it into the profile's existing `outbounds` array; it is not a complete standalone Xray config):

```json
{
  "tag": "wg-de-egress",
  "protocol": "freedom",
  "settings": { "domainStrategy": "UseIP" },
  "streamSettings": {
    "sockopt": { "mark": 375 }
  }
}
```

Example **routing rule** (place it before any broad catch-all rule in the RU profile; replace `YOUR_RU_INBOUND_TAG` with the actual inbound tag shown in that profile):

```json
{
  "type": "field",
  "inboundTag": ["YOUR_RU_INBOUND_TAG"],
  "outboundTag": "wg-de-egress"
}
```

Apply the change through Remnawave's Config Profile management, validate the full generated Xray config before deployment, then test **only the selected inbound**. Do not paste a standalone JSON fragment into an unrelated config field or edit a generated container file that the panel will overwrite. If multiple groups share the same inbound, this rule routes **all** traffic on that inbound, not an individually selected subscription/user. DNS resolution, IPv6 addresses, sniffing and other routing rules need to be evaluated for your specific Xray profile; this installer does not solve them automatically.

> [!WARNING]
> The marked outbound uses a separate routing table: do **not** set `mark: 375` globally for all Xray outbounds, the RemnaNode control-plane or SSH. Do not set a new OS-wide default route to `wg-shadow`.

## Commands and maintenance

```bash
# Either server: status
sudo ./shadowvpn-wg-bridge.sh status

# Germany: persistent inbound firewall rule
systemctl status shadowvpn-wg-de-firewall --no-pager
iptables -S INPUT | grep shadowvpn-wg-bridge
iptables -t nat -S POSTROUTING | grep shadowvpn-wg-bridge

# Both: tunnel and handshake
systemctl status wg-quick@wg-shadow --no-pager
wg show wg-shadow

# Germany: check whether UDP packets reach the host
sudo tcpdump -ni eth0 'udp port 51820'
```

The `tcpdump` example requires `tcpdump` to be installed and assumes Germany's external interface is `eth0`. Substitute the actual external interface if different. Only public keys should be exchanged between servers; never publish `/etc/wireguard/wg-shadow.conf` or `/etc/shadowvpn-wg-bridge/private.key`.

### Upgrade an existing German install from the initial script

The **initial version** of the installer used `iptables -C -t nat ...` in the wrong order and failed while starting WireGuard. It also relied on a manually added, non-persistent UDP INPUT rule. After updating this repository, run **only on Germany**:

```bash
cd /opt/wg-bridge
git pull
sudo ./shadowvpn-wg-bridge.sh de-repair
systemctl status shadowvpn-wg-de-firewall --no-pager
wg show wg-shadow
```

`de-repair` checks for the project's existing WG config, replaces only the project's DE firewall helper, enables the persistent INPUT rule and reapplies the corrected NAT/FORWARD rules without restarting an already-active tunnel. It preserves your WG keys and peer configuration. If the older installation was manually changed beyond the expected project layout, the command refuses to overwrite it; inspect differences first. **You do not need to rerun `ru-init` or regenerate either key pair.**

The persistent INPUT helper runs during boot before WG starts. If another firewall manager later flushes/replaces the INPUT chain, restart the helper and recheck connectivity:

```bash
sudo systemctl restart shadowvpn-wg-de-firewall
```

A separate provider firewall or an nftables chain with a DROP verdict may still prevent packets reaching WireGuard, even if this helper reports success. Verify a new handshake after reboot and after firewall reloads.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `Bad argument 'nat'` | You are using the original firewall helper; update and run `de-repair` on DE. |
| Packets arrive on DE UDP/51820, no handshake | Check DE provider/local INPUT filtering and that the peer public keys match. A packet seen in `tcpdump` may still be dropped before the UDP socket. |
| Handshake works, ping fails | Verify `10.77.250.1/30` and `.2/30`, WG AllowedIPs and host INPUT/OUTPUT rules. |
| Ping works, no Internet via chosen Xray inbound | Check DE forwarding/NAT, Xray outbound mark, inbound routing-rule order, IP family and DNS. |
| SSH affected | Stop modifying rules and recover through the provider console; check that main/default routes and any globally marked sockets are unchanged. |
| Works until reboot or firewall reload | Check `shadowvpn-wg-de-firewall`, `wg-quick@wg-shadow`, provider firewall, and rules installed by other managers. |

### Stop / roll back this bridge

First remove or disable the dedicated `wg-de-egress` routing rule in Remnawave so affected users do not route into a stopped tunnel. Then:

On **RU**:

```bash
sudo systemctl disable --now wg-quick@wg-shadow
```

On **DE**:

```bash
sudo systemctl disable --now wg-quick@wg-shadow
sudo systemctl disable --now shadowvpn-wg-de-firewall
```

The WG `PostDown` hooks remove this project's marked route/rule (RU), or its NAT/FORWARD entries (DE). The separate DE firewall service removes this project's UDP INPUT allow rule. Do **not** flush entire firewall chains or system-wide route tables. The installer does not automatically reverse the DE `net.ipv4.ip_forward=1` sysctl or delete stored keys/configuration; review whether other services rely on forwarding before modifying it.

## Security and operational notes

- Treat SSH, config profiles, WG private keys and the DE endpoint IP as sensitive. Do not commit generated secrets or provider credentials to GitHub.
- Use a DE provider firewall allow-list for RU's public IP where possible. The local firewall rule is intentionally narrow in port/interface, but is not source-IP constrained because RU may change addresses; harden it for your deployment.
- A successful tunnel test does not establish production suitability. Measure latency, throughput, packet loss and reconnection across restarts before directing paying users to it.
- WireGuard encrypts the RU↔DE hop. The DE host still sees and forwards egress traffic. This is **not** end-to-end encryption from the VPN client to the destination website.
- No claims of third-party security audits, universal DPI bypass, zero logs or a specific uptime SLA are made.

## License and contributions

No license has been granted by this README. Add a `LICENSE` file for your chosen license **before** inviting others to reuse or modify this project. Contributions should include the OS/network topology, redacted service logs, clear reproduction steps and, where possible, regression tests for routing/firewall changes. Do not submit WG private keys, tokens or live subscription URLs.
