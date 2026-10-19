#!/usr/bin/env bash
# HAMDMR_DEPLOY_PREFLIGHT=1
# HAMDMR_DEPLOY_PREFLIGHT_V2=1
# HAMDMR_DEPLOY_SHADOW_PREFLIGHT=1
# HAMDMR_SHADOW_PREFLIGHT=1
# HAMDMR_DEPLOY_PRODUCTION_STATE_V1=1
# Galera / HAMDMR · Phase 1B R1 · Write inert WireGuard full-mesh configuration only.
# This script never activates an interface, edits firewall rules, or starts MariaDB/Galera.
set -Eeuo pipefail
trap '_rc=$?; printf "GALERA_PHASE1B_UNEXPECTED_ERROR=rc=%s line=%s\n" "$_rc" "$LINENO" >&2' ERR
umask 077
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

HOST=$(hostname -s)
MODE=${1:---run}
KEY_DIR=/etc/wireguard/hamdmr-galera
KEY_FILE=$KEY_DIR/node.key
PUB_FILE=$KEY_DIR/node.pub
WG_CONF=/etc/wireguard/wg-galera.conf
IFACE=wg-galera
PORT=51871
WG_NET=10.77.68.0/29

# These are PUBLIC keys, not credentials. All private keys stay on their servers.
DMR_PUBLIC=NPZImCHX0N0Rgoh96w6kwYa3ua2x7rWYIffJzS1/rXw=
HAM_PUBLIC=z7BGU3aDxJjSh7urf/SPptUMAfMm5THG2v8utiymED0=
BM1_PUBLIC=T/wOdfa3XlKRwLFnspQ9Jz7icnuvWVQqf/YyaxZu/w0=
DMR_ENDPOINT=185.11.166.85
HAM_ENDPOINT=193.137.237.12
BM1_ENDPOINT=185.11.166.30

fail() { printf 'GALERA_PHASE1B_ERROR=%s\n' "$*" >&2; exit 1; }
state() {
  [[ -n ${HAMDMR_DEPLOY_PRODUCTION_STATE_FILE:-} ]] || return 0
  python3 - "$HAMDMR_DEPLOY_PRODUCTION_STATE_FILE" "$1" "$2" "$3" <<'PY'
import json,sys,pathlib,datetime
p=pathlib.Path(sys.argv[1]);state,phase,reason=sys.argv[2:]
try: obj=json.loads(p.read_text())
except (OSError,ValueError): obj={}
obj.update(schemaVersion=1,protocolVersion=1,declared=True,state=state,phase=phase,reason=reason,updatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'))
p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
PY
}

set_identity() {
  case "$HOST" in
    dmr-portugal)
      LOCAL_IP=10.77.68.11
      PUBLIC=$DMR_PUBLIC
      PEER1_NAME=hamdmr; PEER1_IP=10.77.68.12; PEER1_PUBLIC=$HAM_PUBLIC; PEER1_ENDPOINT=$HAM_ENDPOINT
      PEER2_NAME=bm2681; PEER2_IP=10.77.68.13; PEER2_PUBLIC=$BM1_PUBLIC; PEER2_ENDPOINT=$BM1_ENDPOINT
      MAIN_UNIT=mariadb.service
      ;;
    hamdmr)
      LOCAL_IP=10.77.68.12
      PUBLIC=$HAM_PUBLIC
      PEER1_NAME=dmr-portugal; PEER1_IP=10.77.68.11; PEER1_PUBLIC=$DMR_PUBLIC; PEER1_ENDPOINT=$DMR_ENDPOINT
      PEER2_NAME=bm2681; PEER2_IP=10.77.68.13; PEER2_PUBLIC=$BM1_PUBLIC; PEER2_ENDPOINT=$BM1_ENDPOINT
      MAIN_UNIT=brandmeister@default.service
      ;;
    bm2681)
      LOCAL_IP=10.77.68.13
      PUBLIC=$BM1_PUBLIC
      PEER1_NAME=dmr-portugal; PEER1_IP=10.77.68.11; PEER1_PUBLIC=$DMR_PUBLIC; PEER1_ENDPOINT=$DMR_ENDPOINT
      PEER2_NAME=hamdmr; PEER2_IP=10.77.68.12; PEER2_PUBLIC=$HAM_PUBLIC; PEER2_ENDPOINT=$HAM_ENDPOINT
      MAIN_UNIT=brandmeister@default.service
      ;;
    *) fail "Unauthorized hostname: $HOST" ;;
  esac
}

ensure_basics() {
  [[ $(id -u) -eq 0 ]] || fail 'Root required'
  set_identity
  for c in wg wg-quick ip python3 systemctl stat cmp mktemp install flock; do
    command -v "$c" >/dev/null 2>&1 || fail "Missing command: $c"
  done
  [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] || fail 'NTP not synchronized'
  [[ -e $KEY_FILE && -e $PUB_FILE ]] || fail 'Phase 1A private and public keys missing'
  [[ ! -L /etc/wireguard && ! -L $KEY_DIR && ! -L $KEY_FILE && ! -L $PUB_FILE && ! -L $WG_CONF ]] || fail 'Unexpected symlink in WireGuard paths'
  [[ -d /etc/wireguard && -d $KEY_DIR && -f $KEY_FILE && -f $PUB_FILE ]] || fail 'Unexpected WireGuard key paths'
  [[ $(stat -c '%u:%g:%a' "$KEY_FILE") == 0:0:600 ]] || fail 'Private key ownership/mode invalid'
  [[ $(stat -c '%u:%g:%a' "$KEY_DIR") == 0:0:700 ]] || fail 'Key directory ownership/mode invalid'
  local actual_pub
  actual_pub=$(wg pubkey < "$KEY_FILE") || fail 'Private key invalid'
  [[ $actual_pub == "$PUBLIC" ]] || fail 'Local private key does not match public key recorded in topology'
  [[ $(< "$PUB_FILE") == "$PUBLIC" ]] || fail 'Local node.pub differs from expected public key'
  systemctl is-active --quiet "$MAIN_UNIT" || fail "Critical service inactive: $MAIN_UNIT"
  if [[ $HOST == dmr-portugal ]]; then
    systemctl is-active --quiet mariadb.socket || fail 'Production MariaDB socket inactive'
  fi
  if ip link show dev "$IFACE" >/dev/null 2>&1; then
    fail "Interface $IFACE already exists: existing setup must be reviewed first"
  fi
  if systemctl is-active --quiet "wg-quick@${IFACE}.service"; then
    fail 'WireGuard systemd service already active'
  fi
  if [[ -e $WG_CONF ]]; then
    [[ -f $WG_CONF && $(stat -c '%u:%g:%a' "$WG_CONF") == 0:0:600 ]] || fail 'Existing configuration must be a root:root 0600 regular file'
  fi
  # Fail closed for any existing explicit address or route overlapping the private mesh subnet.
  python3 - "$WG_NET" <<'PY'
import ipaddress,json,subprocess,sys
want=ipaddress.ip_network(sys.argv[1],strict=True)
for kind,cmd in [('address',['ip','-j','-4','address','show']),('route',['ip','-j','-4','route','show','table','all'])]:
  try: items=json.loads(subprocess.check_output(cmd,text=True,stderr=subprocess.DEVNULL))
  except (subprocess.CalledProcessError,ValueError) as exc:
    raise SystemExit(f'GALERA_PHASE1B_ERROR=Cannot inspect {kind}: {exc}')
  for item in items:
    entries=item.get('addr_info',[]) if kind=='address' else [item]
    for x in entries:
      if kind=='address':
        if x.get('family')!='inet': continue
        v=f"{x['local']}/{x['prefixlen']}"
      else:
        v=x.get('dst','default')
        if v=='default': continue
      try: net=ipaddress.ip_network(v,strict=False)
      except ValueError: continue
      if net.overlaps(want):
        raise SystemExit(f'GALERA_PHASE1B_ERROR=Existing {kind} {net} overlaps reserved {want}')
PY
}

render_conf() {
  local private
  private=$(<"$KEY_FILE")
  cat <<EOF
# HAMDMR / Galera · Phase 1B · full mesh · staged (do NOT expose this file)
[Interface]
Address = $LOCAL_IP/32
ListenPort = $PORT
PrivateKey = $private

# Peer: $PEER1_NAME
[Peer]
PublicKey = $PEER1_PUBLIC
AllowedIPs = $PEER1_IP/32
Endpoint = $PEER1_ENDPOINT:$PORT
PersistentKeepalive = 25

# Peer: $PEER2_NAME
[Peer]
PublicKey = $PEER2_PUBLIC
AllowedIPs = $PEER2_IP/32
Endpoint = $PEER2_ENDPOINT:$PORT
PersistentKeepalive = 25
EOF
}

check_existing_matches() {
  [[ -e $WG_CONF ]] || return 0
  # Preflight must not touch the filesystem, even when checking an existing config.
  cmp -s <(render_conf) "$WG_CONF" || fail 'Existing wg-galera.conf differs; refusing overwrite' 
}

preflight() {
  ensure_basics
  check_existing_matches
  printf 'GALERA_PHASE1B_PREFLIGHT=PASS\nHOST=%s\nPRIVATE_ADDRESS=%s/32\nWG_PORT_UDP=%s\n' "$HOST" "$LOCAL_IP" "$PORT"
  if [[ -f $WG_CONF ]]; then echo 'CONFIG=ALREADY_STAGED'; else echo 'CONFIG=NOT_YET_STAGED'; fi
  echo 'INTERFACE_UP=NO'
  echo 'FIREWALL_CHANGED=NO'
  echo 'PRODUCTION_SQL_CHANGED=NO'
}

stage() {
  preflight
  local before after temp
  before=$(systemctl show -P MainPID "$MAIN_UNIT")
  exec 9>/run/lock/hamdmr-galera-phase1b.lock
  flock -n 9 || fail 'Another Galera stage is running'
  preflight
  if [[ ! -e $WG_CONF ]]; then
    temp=$(mktemp /etc/wireguard/.wg-galera-stage.XXXXXXXX.conf) || fail 'Cannot stage config'
    chmod 600 "$temp"
    render_conf > "$temp"
    # validate with wg-quick parser; never send config to stdout / logs
    wg-quick strip "$temp" >/dev/null 2>&1 || { rm -f "$temp"; fail 'Generated WireGuard syntax invalid'; }
    state changed config 'Local WireGuard config staged without activation'
    mv -n -- "$temp" "$WG_CONF" || { rm -f "$temp"; fail 'Cannot move prepared config into place'; }
    [[ -e $WG_CONF ]] || fail 'Configuration not present after move'
    chmod 600 "$WG_CONF"
  else
    state unchanged config 'Identical local WireGuard config already staged'
  fi
  after=$(systemctl show -P MainPID "$MAIN_UNIT")
  [[ "$before" == "$after" ]] || fail 'Critical service PID changed during staging'
  [[ -f $WG_CONF && $(stat -c '%u:%g:%a' "$WG_CONF") == 0:0:600 ]] || fail 'Staged file ownership or mode invalid'
  check_existing_matches
  [[ ! -e /sys/class/net/$IFACE ]] || fail 'Unexpected WireGuard interface found after stage'
  printf '\nGALERA_PHASE1B=STAGED\nHOST=%s\nPRIVATE_ADDRESS=%s/32\nINTERFACE_UP=NO\nFIREWALL_CHANGED=NO\nPRODUCTION_SQL_CHANGED=NO\n' "$HOST" "$LOCAL_IP"
  echo 'NEXT_STEP=Review firewalls and activate all three peers in a controlled sequence'
}

case "$MODE" in
  --preflight|--check) preflight ;;
  --shadow-preflight) preflight; echo 'HAMDMR_SHADOW_PREFLIGHT=PASS' ;;
  --run|--stage) stage ;;
  *) fail "Unsupported option: $MODE" ;;
esac
