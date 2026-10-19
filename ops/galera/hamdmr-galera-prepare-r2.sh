#!/usr/bin/env bash
# HAMDMR/DMR-PORTUGAL/BM2681 · Galera · Preparação de 3 nós · R2
# Modos: --check (sem alterações), --prepare (instala/configura mas NAO inicia MariaDB Galera).
set -Eeuo pipefail
umask 077
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

NAME=hamdmr-galera
CONF=/etc/mysql/hamdmr-galera.cnf
DATADIR=/var/lib/hamdmr-galera
SQL_SOCKET=/run/hamdmr-galera/mysqld.sock
FWSCRIPT=/usr/local/sbin/hamdmr-galera-firewall
FWUNIT=/etc/systemd/system/hamdmr-galera-firewall.service
DBUNIT=/etc/systemd/system/hamdmr-galera.service
WG_DROPIN=/etc/systemd/system/wg-quick@wg-galera.service.d/hamdmr-galera-firewall.conf
BRANCH_MARK=$DATADIR/.hamdmr-initial-bootstrap-allowed
PORT_WG=51871
SQL_PORT=3307
HOST=$(hostname -s)
MODE=${1:---check}
POLICY_ADDED=0
TMPDIR_CREATED=''

cleanup() {
  local code=$?
  if ((POLICY_ADDED)); then rm -f /usr/sbin/policy-rc.d; fi
  if [[ -n $TMPDIR_CREATED ]]; then rm -rf -- "$TMPDIR_CREATED"; fi
  if ((code)); then printf 'GALERA_PREPARE_ERROR=rc:%s line:%s\n' "$code" "$BASH_LINENO" >&2; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'GALERA_PREPARE_BLOCKED=%s\n' "$*" >&2; exit 1; }

case "$HOST" in
  dmr-portugal) PRIVATE_IP=10.77.68.11; PEER1=193.137.237.12; PEER2=185.11.166.30; WG1=10.77.68.12; WG2=10.77.68.13; CRITICAL=mariadb.service; MEM=384M ;;
  hamdmr) PRIVATE_IP=10.77.68.12; PEER1=185.11.166.85; PEER2=185.11.166.30; WG1=10.77.68.11; WG2=10.77.68.13; CRITICAL=brandmeister@default.service; MEM=256M ;;
  bm2681) PRIVATE_IP=10.77.68.13; PEER1=185.11.166.85; PEER2=193.137.237.12; WG1=10.77.68.11; WG2=10.77.68.12; CRITICAL=brandmeister@default.service; MEM=256M ;;
  *) fail "Host nao autorizado: $HOST" ;;
esac

cmd() { command -v "$1" >/dev/null 2>&1 || fail "Falta comando: $1"; }
check() {
  [[ $(id -u) == 0 ]] || fail 'Executar como root'
  for c in systemctl ip iptables iptables-save wg wg-quick stat sha256sum awk sort ss gzip findmnt systemd-analyze; do cmd "$c"; done
  systemctl is-active --quiet "$CRITICAL" || fail "Servico critico inativo: $CRITICAL"
  [[ -d /sys/class/net/wg-galera ]] || fail 'Túnel wg-galera nao esta ativo'
  [[ -f /etc/wireguard/wg-galera.conf ]] || fail 'Configuracao WireGuard ausente'
  [[ $(stat -c '%a' /etc/wireguard/wg-galera.conf) == 600 ]] || fail 'Permissoes WireGuard inseguras'
  ip -4 -o addr show dev wg-galera | grep -F "$PRIVATE_IP/32" >/dev/null || fail 'Endereco WireGuard inesperado'
  ip -4 route get "$WG1" | grep -F 'dev wg-galera' >/dev/null || fail 'Rota peer1 nao usa WireGuard'
  ip -4 route get "$WG2" | grep -F 'dev wg-galera' >/dev/null || fail 'Rota peer2 nao usa WireGuard'
  [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || fail 'NTP nao sincronizado'
  for p in 3307 4444 4567 4568; do
    if ss -H -lnt "sport = :$p" 2>/dev/null | grep -q .; then fail "TCP $p ja em escuta"; fi
  done
  if ss -H -lnu 'sport = :4567' 2>/dev/null | grep -q .; then fail 'UDP 4567 ja em escuta'; fi
  if [[ $HOST == dmr-portugal ]]; then
    cmd mariadbd
    systemctl is-active --quiet mariadb.socket || fail 'MariaDB socket de producao inativo'
    [[ $(mariadb --no-defaults -Nse 'SELECT @@port' 2>/dev/null) == 3306 ]] || fail 'MariaDB producao nao responde na porta esperada'
    local baseline
    baseline=$(find /root/backups -mindepth 2 -maxdepth 2 -type f \
      -path '/root/backups/dmr-mariadb-baseline-*/mariadb-all.sql.gz' -newermt '2026-10-19' \
      -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}')
    [[ -n $baseline ]] || fail 'Backup integral recente nao identificado'
    (cd "${baseline%/*}" && sha256sum -c SHA256SUMS >/dev/null && gzip -t mariadb-all.sql.gz) || fail 'Backup integral falhou verificacao'
  else
    if command -v mariadbd >/dev/null 2>&1; then
      [[ $(dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null) == 1:11.8.6-* ]] || fail 'MariaDB preexistente em versao diferente'
    fi
    cmd apt-get
    [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]] || fail 'politica policy-rc.d preexistente: rever manualmente'
    local sim
    sim=$(apt-get -s --no-install-recommends install mariadb-server galera-4 rsync socat) || fail 'Simulacao APT falhou'
    if grep -q '^Remv ' <<< "$sim"; then fail 'Instalacao removeria pacotes'; fi
    if grep -E '^Inst (brandmeister|linux-image)' <<< "$sim"; then fail 'APT propoe upgrade de servicos criticos'; fi
  fi
  [[ $(findmnt -n -o FSTYPE /) == ext4 || $(findmnt -n -o FSTYPE /) == xfs ]] || fail 'Sistema de ficheiros nao revisto'
  [[ -f "$CONF" ]] && fail "Config Galera ja existe; nao reinstalar automaticamente ($CONF)"
  [[ -e "$DBUNIT" ]] && fail 'Unidade Galera ja existe'
  [[ -e "$FWSCRIPT" ]] && fail 'Firewall Galera ja instalada'
  [[ -e "$FWUNIT" ]] && fail 'Firewall unit ja instalada'
  [[ -e "$WG_DROPIN" ]] && fail 'Drop-in WireGuard ja instalado'
  [[ -e "$DATADIR" ]] && fail 'Datadir Galera ja existe; evitar perda de dados'
  [[ -e "$BRANCH_MARK" ]] && fail 'Marcador de bootstrap ja existe'
  [[ -e /etc/wireguard/wg-galera.conf ]] || fail 'Config WireGuard ausente'
  [[ ! -L /etc/mysql && ! -L /etc/systemd/system && ! -L /usr/local/sbin ]] || fail 'Diretoria administrativa symlink inesperada'
  printf 'GALERA_PHASE2_PREFLIGHT=PASS HOST=%s WG_IP=%s PORT=%s CRITICAL=ACTIVE\n' "$HOST" "$PRIVATE_IP" "$SQL_PORT"
}

# Instala pacote de servidor nos nós sem MariaDB, bloqueando temporariamente
# arranques automáticos por maintscripts durante o apt-get. A política é removida sempre.
install_packages() {
  if [[ $HOST != dmr-portugal ]]; then
    if [[ ! -x /usr/sbin/policy-rc.d ]]; then
      cat > /usr/sbin/policy-rc.d <<'POLICY'
#!/bin/sh
# Temporal: evita inicio automatico durante a instalacao do MariaDB Galera isolado
exit 101
POLICY
      chmod 700 /usr/sbin/policy-rc.d
      POLICY_ADDED=1
    fi
    apt-get install -y --no-install-recommends mariadb-server galera-4 rsync socat
    rm -f /usr/sbin/policy-rc.d
    POLICY_ADDED=0
    # O serviço MariaDB padrao não faz parte da arquitetura do cluster.
    if systemctl is-active --quiet mariadb.service || systemctl is-active --quiet mariadb.socket; then
      fail 'MariaDB padrao arrancou inesperadamente: verificar, NAO parar automaticamente'
    fi
    systemctl disable mariadb.service mariadb.socket >/dev/null 2>&1 || true
  else
    # DMR: nunca executar apt, substituir arquivos da instalação, ou reiniciar MariaDB.
    cmd mariadbd
  fi
  cmd mariadb-install-db
  [[ -f /usr/lib/galera/libgalera_smm.so ]] || fail 'wsrep_provider Galera nao encontrado'
  cmd rsync
  cmd socat
}

write_once() {
  local dst=$1 mode=$2 src=$3
  [[ ! -e $dst && ! -L $dst ]] || fail "Destino nao vazio: $dst"
  install -o root -g root -m "$mode" "$src" "$dst"
}

make_config() {
  cat > "$TMPDIR_CREATED/db.cnf" <<EOF
# HAMDMR Galera · Instancia isolada (NAO ALTERAR mariadb.service de producao)
[mariadbd]
user=mysql
datadir=$DATADIR
socket=$SQL_SOCKET
pid-file=/run/hamdmr-galera/mysqld.pid
port=$SQL_PORT
bind-address=$PRIVATE_IP
skip-name-resolve=1
max_connections=48
innodb_buffer_pool_size=$MEM
innodb_log_file_size=64M
innodb_autoinc_lock_mode=2
default_storage_engine=InnoDB
binlog_format=ROW
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so
wsrep_cluster_name=hamdmr-galera
wsrep_cluster_address=gcomm://10.77.68.11,10.77.68.12,10.77.68.13
wsrep_node_name=$HOST
wsrep_node_address=$PRIVATE_IP
wsrep_sst_method=rsync
wsrep_sst_receive_address=$PRIVATE_IP:4444
wsrep_provider_options=gcache.size=128M;gmcast.listen_addr=tcp://$PRIVATE_IP:4567
wsrep_slave_threads=2
EOF
  cat > "$TMPDIR_CREATED/db.service" <<'UNIT'
[Unit]
Description=HAMDMR Galera · isolated MariaDB node (not production mariadb.service)
Documentation=https://mariadb.com/docs/galera-cluster/
Wants=network-online.target
After=network-online.target wg-quick@wg-galera.service hamdmr-galera-firewall.service
Requires=hamdmr-galera-firewall.service
ConditionPathExists=/etc/mysql/hamdmr-galera.cnf

[Service]
Type=notify
User=mysql
Group=mysql
RuntimeDirectory=hamdmr-galera
RuntimeDirectoryMode=0750
ExecStartPre=/usr/bin/test -d /sys/class/net/wg-galera
ExecStart=/usr/sbin/mariadbd --defaults-file=/etc/mysql/hamdmr-galera.cnf $HAMDMR_GALERA_BOOTSTRAP
TimeoutStartSec=900
TimeoutStopSec=120
Restart=no
LimitNOFILE=32768
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  cat > "$TMPDIR_CREATED/wgdrop.conf" <<'DROPIN'
[Unit]
Requires=hamdmr-galera-firewall.service
After=hamdmr-galera-firewall.service
DROPIN
  cat > "$TMPDIR_CREATED/firewall.service" <<'UNIT'
[Unit]
Description=HAMDMR Galera · persist exact WireGuard/SQL peer firewall before WireGuard startup
Before=wg-quick@wg-galera.service
After=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hamdmr-galera-firewall
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
UNIT
  cat > "$TMPDIR_CREATED/firewall" <<'FW'
#!/usr/bin/env bash
set -Eeuo pipefail
HOST=$(hostname -s)
case "$HOST" in
 dmr-portugal) P1=193.137.237.12; P2=185.11.166.30; IP1=10.77.68.12; IP2=10.77.68.13 ;;
 hamdmr) P1=185.11.166.85; P2=185.11.166.30; IP1=10.77.68.11; IP2=10.77.68.13 ;;
 bm2681) P1=185.11.166.85; P2=193.137.237.12; IP1=10.77.68.11; IP2=10.77.68.12 ;;
 *) echo 'Unexpected host' >&2; exit 1 ;;
esac
WGCHAIN=GALERA_WG
DBCHAIN=GALERA_DB
ensure_chain() { iptables -w -nL "$1" >/dev/null 2>&1 || iptables -w -N "$1"; }
ensure_chain "$WGCHAIN"
ensure_chain "$DBCHAIN"
# Prevent taking over unrelated chains. Require exactly the known allowlists.
if [[ $(iptables -w -S "$WGCHAIN" | wc -l) == 1 ]]; then
 iptables -w -A "$WGCHAIN" -s "$P1/32" -j ACCEPT
 iptables -w -A "$WGCHAIN" -s "$P2/32" -j ACCEPT
 iptables -w -A "$WGCHAIN" -j DROP
fi
[[ $(iptables -w -S "$WGCHAIN" | wc -l) == 4 ]] || { echo 'Unexpected WireGuard chain' >&2; exit 1; }
iptables -w -C "$WGCHAIN" -s "$P1/32" -j ACCEPT
iptables -w -C "$WGCHAIN" -s "$P2/32" -j ACCEPT
iptables -w -C "$WGCHAIN" -j DROP
if [[ $(iptables -w -S "$DBCHAIN" | wc -l) == 1 ]]; then
 iptables -w -A "$DBCHAIN" -i lo -j ACCEPT
 iptables -w -A "$DBCHAIN" -i wg-galera -s "$IP1/32" -j ACCEPT
 iptables -w -A "$DBCHAIN" -i wg-galera -s "$IP2/32" -j ACCEPT
 iptables -w -A "$DBCHAIN" -j DROP
fi
[[ $(iptables -w -S "$DBCHAIN" | wc -l) == 5 ]] || { echo 'Unexpected DB chain' >&2; exit 1; }
iptables -w -C "$DBCHAIN" -i lo -j ACCEPT
iptables -w -C "$DBCHAIN" -i wg-galera -s "$IP1/32" -j ACCEPT
iptables -w -C "$DBCHAIN" -i wg-galera -s "$IP2/32" -j ACCEPT
iptables -w -C "$DBCHAIN" -j DROP
iptables -w -C INPUT -p udp --dport 51871 -j "$WGCHAIN" || iptables -w -I INPUT 1 -p udp --dport 51871 -j "$WGCHAIN"
iptables -w -C INPUT -p tcp -m multiport --dports 3307,4444,4567,4568 -j "$DBCHAIN" || iptables -w -I INPUT 1 -p tcp -m multiport --dports 3307,4444,4567,4568 -j "$DBCHAIN"
iptables -w -C INPUT -p udp --dport 4567 -j "$DBCHAIN" || iptables -w -I INPUT 1 -p udp --dport 4567 -j "$DBCHAIN"
echo "GALERA_FIREWALL=PEER_ONLY host=$HOST"
FW
}

prepare() {
  check
  local before_pid after_pid
  before_pid=$(systemctl show -P MainPID "$CRITICAL")
  exec 9>/run/lock/hamdmr-galera-prepare.lock
  flock -n 9 || fail 'Preparacao concorrente detetada'
  TMPDIR_CREATED=$(mktemp -d /tmp/hamdmr-galera-stage.XXXXXXXX)
  install_packages
  make_config
  bash -n "$TMPDIR_CREATED/firewall"
  # MariaDB sees only the isolated config; defaults-file is always the first option.
  # Validate MariaDB 11.8's actual options and display actionable diagnostics on failure.
  local sql_check_rc=0
  /usr/sbin/mariadbd --defaults-file="$TMPDIR_CREATED/db.cnf" --verbose --help \
    >"$TMPDIR_CREATED/mariadbd-check.log" 2>&1 || sql_check_rc=$?
  if ((sql_check_rc != 0)); then
    echo "GALERA_SQL_VALIDATE_RC=$sql_check_rc" >&2
    echo '=== MARIADB · ERRO REAL DA CONFIGURACAO ===' >&2
    grep -iE 'unknown|error|failed|invalid|not found|denied|warning' \
      "$TMPDIR_CREATED/mariadbd-check.log" | tail -n 30 >&2 || true
    echo '=== MARIADB · ULTIMAS LINHAS ===' >&2
    tail -n 12 "$TMPDIR_CREATED/mariadbd-check.log" >&2 || true
    fail 'Configuracao SQL invalida: consultar erro MariaDB acima'
  fi
  echo 'GALERA_SQL_CONFIG_VALID=YES'
  install -d -o mysql -g mysql -m 0700 "$DATADIR"
  if find "$DATADIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then fail 'Datadir nao vazia antes da inicializacao'; fi
  # Isolado: init-db nao carrega configuracoes de outras instancias MariaDB.
  mariadb-install-db --no-defaults --user=mysql --datadir="$DATADIR" \
    --auth-root-authentication-method=socket --skip-test-db >/dev/null
  [[ -d "$DATADIR/mysql" ]] || fail 'Tabelas sistemicas nao inicializadas'
  touch "$BRANCH_MARK"
  chmod 0600 "$BRANCH_MARK"
  chown mysql:mysql "$BRANCH_MARK"
  install -d -m 0755 /etc/mysql
  install -d -m 0755 /etc/systemd/system/wg-quick@wg-galera.service.d
  write_once "$CONF" 0644 "$TMPDIR_CREATED/db.cnf"
  write_once "$DBUNIT" 0644 "$TMPDIR_CREATED/db.service"
  write_once "$FWUNIT" 0644 "$TMPDIR_CREATED/firewall.service"
  write_once "$WG_DROPIN" 0644 "$TMPDIR_CREATED/wgdrop.conf"
  write_once "$FWSCRIPT" 0750 "$TMPDIR_CREATED/firewall"
  systemd-analyze verify "$DBUNIT" "$FWUNIT" >/dev/null 2>&1 || fail 'Unidades systemd invalidas apos instalacao'
  systemctl daemon-reload
  # A interface esta ja ativa MANUALMENTE. So habilitar para o proximo boot.
  systemctl enable wg-quick@wg-galera.service >/dev/null
  systemctl enable --now hamdmr-galera-firewall.service
  systemctl is-active --quiet hamdmr-galera-firewall.service || fail 'Firewall Galera persistente inativa'
  [[ $(systemctl is-enabled hamdmr-galera.service) == disabled ]] || fail 'Galera SQL foi ativado inesperadamente'
  if systemctl is-active --quiet hamdmr-galera.service; then fail 'Galera SQL iniciou inesperadamente'; fi
  after_pid=$(systemctl show -P MainPID "$CRITICAL")
  [[ $before_pid == "$after_pid" ]] || fail 'PID do servico critico foi alterado'
  if [[ $HOST == dmr-portugal ]]; then
    [[ $(mariadb --no-defaults -Nse 'SELECT @@port') == 3306 ]] || fail 'MariaDB producao nao responde apos instalacao'
  fi
  echo "GALERA_PHASE2=PREPARED HOST=$HOST NODE=$PRIVATE_IP MYSQL_PORT=$SQL_PORT"
  echo 'WIREGUARD_PERSISTENT=ENABLED FIREWALL_PERSISTENT=ENABLED'
  echo 'GALERA_SQL=INSTALLED_NOT_STARTED GALERA_AUTOSTART=DISABLED'
  echo 'PRODUCTION_SERVICE_PID=UNCHANGED'
}

case "$MODE" in
 --check) check ;;
 --prepare) prepare ;;
 *) fail "Modo nao suportado: $MODE" ;;
esac
