#!/usr/bin/env bash
# HAMDMR / Galera Phase 1C R1 · Read-only firewall / WireGuard readiness
# Does not modify firewall, network, configs, packages, systemd or Galera.
set -Eeuo pipefail
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
readonly NAME=hamdmr-galera-phase1c-firewall-audit-r1
readonly WG_CONF=/etc/wireguard/wg-galera.conf
readonly KEY_DIR=/etc/wireguard/hamdmr-galera
readonly PORT=51871
HOST=$(hostname -s)
fail(){ printf 'GALERA_PHASE1C_AUDIT_ERROR=%s\n' "$*" >&2; exit 1; }

case "$HOST" in
  dmr-portugal)
    LOCAL=10.77.68.11
    PEER_A='hamdmr|193.137.237.12|10.77.68.12'
    PEER_B='bm2681|185.11.166.30|10.77.68.13'
    CRITICAL=mariadb.service
    ;;
  hamdmr)
    LOCAL=10.77.68.12
    PEER_A='dmr-portugal|185.11.166.85|10.77.68.11'
    PEER_B='bm2681|185.11.166.30|10.77.68.13'
    CRITICAL=brandmeister@default.service
    ;;
  bm2681)
    LOCAL=10.77.68.13
    PEER_A='dmr-portugal|185.11.166.85|10.77.68.11'
    PEER_B='hamdmr|193.137.237.12|10.77.68.12'
    CRITICAL=brandmeister@default.service
    ;;
  *) fail "Unexpected host: $HOST";;
esac
[[ $(id -u) -eq 0 ]] || fail 'Must run as root'
for c in wg wg-quick ip ss stat systemctl awk grep; do command -v "$c" >/dev/null || fail "Missing $c"; done
[[ ! -L "$WG_CONF" && -f "$WG_CONF" ]] || fail 'WireGuard config absent / symlink'
[[ $(stat -c '%u:%g:%a' "$WG_CONF") == '0:0:600' ]] || fail 'Unexpected config ownership or permissions'
[[ $(stat -c '%u:%g:%a' "$KEY_DIR/node.key") == '0:0:600' ]] || fail 'Unexpected key ownership or permissions'
wg-quick strip "$WG_CONF" >/dev/null || fail 'WireGuard config parser rejected staged config'
[[ $(grep -Fxc "Address = $LOCAL/32" "$WG_CONF") -eq 1 ]] || fail 'Unexpected WireGuard address'
[[ $(grep -Fxc "ListenPort = $PORT" "$WG_CONF") -eq 1 ]] || fail 'Unexpected WireGuard port'
for peer in "$PEER_A" "$PEER_B"; do
  IFS='|' read -r peer_name peer_public peer_private <<< "$peer"
  [[ $(grep -Fxc "AllowedIPs = $peer_private/32" "$WG_CONF") -eq 1 ]] || fail "Unexpected AllowedIPs: $peer_name"
  [[ $(grep -Fxc "Endpoint = $peer_public:$PORT" "$WG_CONF") -eq 1 ]] || fail "Unexpected endpoint: $peer_name"
done
[[ $(< "$KEY_DIR/node.pub") == "$(wg pubkey < "$KEY_DIR/node.key")" ]] || fail 'Private/public key mismatch'

printf 'GALERA_PHASE1C_AUDIT=R1\nHOST=%s\nCONFIG_VALID=YES\nLOCAL=%s\nPORT_UDP=%s\n' "$HOST" "$LOCAL" "$PORT"
printf '=== INTERFACE AND CRITICAL SERVICE ===\n'
if ip link show dev wg-galera >/dev/null 2>&1; then
  echo 'INTERFACE=UP_OR_PRESENT'
else
  echo 'INTERFACE=ABSENT'
fi
printf 'WG_QUICK_ACTIVE='; systemctl is-active wg-quick@wg-galera.service || :
printf 'WG_QUICK_ENABLED='; systemctl is-enabled wg-quick@wg-galera.service || :
printf 'CRITICAL_SERVICE=%s\n' "$CRITICAL"
printf 'CRITICAL_SERVICE_STATE='; systemctl is-active "$CRITICAL" || :
if [[ "$HOST" == dmr-portugal ]]; then
  printf 'MARIADB_SOCKET='; systemctl is-active mariadb.socket || :
fi

printf '\n=== UDP SOCKET %s (SHOULD BE FREE BEFORE ACTIVATION) ===\n' "$PORT"
ss -H -lunp "( sport = :$PORT )" || :

printf '\n=== PEER PUBLIC ROUTES ===\n'
for peer in "$PEER_A" "$PEER_B"; do
  IFS='|' read -r peer_name peer_public peer_private <<< "$peer"
  printf 'PEER=%s PUBLIC=%s PRIVATE=%s ROUTE: ' "$peer_name" "$peer_public" "$peer_private"
  ip -4 route get "$peer_public" || :
done

printf '\n=== FIREWALL TOOLS ===\n'
for c in nft iptables iptables-save ufw firewall-cmd; do
  if command -v "$c" >/dev/null 2>&1; then printf '%s=PRESENT\n' "$c"; else printf '%s=ABSENT\n' "$c"; fi
done
if command -v iptables >/dev/null 2>&1; then
  printf '\n=== IPTABLES BACKEND / INPUT POLICY AND JUMPS ===\n'
  iptables -V || :
  iptables -S INPUT 2>&1 || :
fi
if command -v nft >/dev/null 2>&1; then
  printf '\n=== NFT FILTER RELEVANT RULES (UP TO 130; FULL INPUT SCANNED) ===\n'
  nft -a list ruleset 2>/dev/null | awk '
    /table |chain |hook input|policy |udp |dport|iifname|saddr|jump |goto |drop|reject|accept/ {
      lines++
      if(lines<=130) print
    }
    END {printf "NFT_MATCHING_LINES=%d\nNFT_LINES_DISPLAYED=%d\n",lines,(lines<130?lines:130)}'
fi
printf '\n=== SYSTEM SERVICES / NO CHANGES ===\n'
echo 'FIREWALL_CHANGED=NO'
echo 'WIREGUARD_INTERFACE_CHANGED=NO'
echo 'MARIADB_OR_BRANDMEISTER_CHANGED=NO'
echo 'GALERA_PHASE1C_FIREWALL_REVIEW=PENDING'
echo 'GALERA_PHASE1C_AUDIT=OK'
