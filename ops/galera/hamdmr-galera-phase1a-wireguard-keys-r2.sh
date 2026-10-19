#!/usr/bin/env bash
# HAMDMR_DEPLOY_PREFLIGHT=1
# HAMDMR_DEPLOY_PREFLIGHT_V2=1
# HAMDMR_DEPLOY_SHADOW_PREFLIGHT=1
# HAMDMR_SHADOW_PREFLIGHT=1
# HAMDMR_DEPLOY_PRODUCTION_STATE_V1=1
# HAMDMR Galera · Fase 1A R2 · Preparar chaves locais WireGuard sem ativar rede
# Origem publica: apenas codigo generico; segredos gerados e guardados localmente.
set -Eeuo pipefail
trap '_exit=$?; printf "GALERA_PHASE1A_UNEXPECTED_ERROR=rc=%s line=%s\n" "$_exit" "$LINENO" >&2' ERR
umask 077
export LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l SYSTEMD_PAGER=cat SYSTEMD_COLORS=0

NAME=hamdmr-galera-phase1a-wireguard-keys-r2
KEY_DIR=/etc/wireguard/hamdmr-galera
KEY_FILE=$KEY_DIR/node.key
PUB_FILE=$KEY_DIR/node.pub
HOST=$(hostname -s)
MODE=${1:---run}

fail() { printf 'GALERA_PHASE1A_ERROR=%s\n' "$*" >&2; exit 1; }
state() {
    [[ -n ${HAMDMR_DEPLOY_PRODUCTION_STATE_FILE:-} ]] || return 0
    python3 - "$HAMDMR_DEPLOY_PRODUCTION_STATE_FILE" "$1" "$2" "$3" <<'PY'
import datetime,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);status,phase,reason=sys.argv[2:]
try: obj=json.loads(p.read_text())
except (OSError,ValueError): obj={}
obj.update(schemaVersion=1,protocolVersion=1,declared=True,state=status,phase=phase,reason=reason,updatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'))
p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')
PY
}
check_host() {
    [[ $(id -u) -eq 0 ]] || fail 'Executar como root'
    case $HOST in dmr-portugal|hamdmr|bm2681) ;; *) fail "Host nao autorizado: $HOST";; esac
    command -v apt-get >/dev/null || fail 'APT indisponivel'
    command -v apt-cache >/dev/null || fail 'apt-cache indisponivel'
    command -v systemctl >/dev/null || fail 'systemctl indisponivel'
    command -v python3 >/dev/null || fail 'python3 indisponivel'
    command -v flock >/dev/null || fail 'flock indisponivel'
    [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] || fail 'NTP nao sincronizado'
    [[ ! -L "$KEY_DIR" && ! -L "$KEY_FILE" && ! -L "$PUB_FILE" ]] || fail 'Symlink inesperado no destino das chaves'
    if [[ -e "$KEY_DIR" ]]; then
        [[ -d "$KEY_DIR" && $(stat -c '%u:%g' "$KEY_DIR") == 0:0 ]] || fail 'Diretorio de chaves invalido'
    fi
    if [[ -e "$KEY_FILE" ]]; then
        [[ -f "$KEY_FILE" && $(stat -c '%u:%g' "$KEY_FILE") == 0:0 && $(stat -c '%a' "$KEY_FILE") == 600 ]] || fail 'Chave existente com dono/permissoes inesperados'
        if command -v wg >/dev/null 2>&1; then
            wg pubkey < "$KEY_FILE" >/dev/null || fail 'Chave privada existente invalida'
        fi
    fi
    if [[ $HOST == dmr-portugal ]]; then
        systemctl is-active --quiet mariadb.service || fail 'MariaDB de producao inativo'
        systemctl is-active --quiet mariadb.socket || fail 'Socket MariaDB de producao inativo'
        # Salvaguarda atual obrigatoria antes de alteracoes de pacotes no DMR-PORTUGAL.
        local latest
        latest=$(find /root/backups -mindepth 2 -maxdepth 2 -type f \
            -path '/root/backups/dmr-mariadb-baseline-*/mariadb-all.sql.gz' \
            -newermt '2026-10-19 00:00:00' -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr | awk 'NR == 1 {print $2}')
        [[ -n $latest ]] || fail 'Backup integral MariaDB de 19/10 ainda nao identificado em /root/backups/dmr-mariadb-baseline-*'
        local backup_dir
        backup_dir=${latest%/mariadb-all.sql.gz}
        [[ -f $backup_dir/SHA256SUMS ]] || fail 'Backup MariaDB sem ficheiro de verificacao SHA256SUMS'
        (cd "$backup_dir" && sha256sum -c SHA256SUMS >/dev/null && gzip -t mariadb-all.sql.gz) \
          || fail 'Integridade do backup MariaDB nao validada'
        echo 'GALERA_PHASE1A_MARIADB_BASELINE=SHA256_GZIP_OK'
    else
        systemctl is-active --quiet brandmeister@default.service || fail 'BrandMeister inativo'
    fi
    if ! command -v wg >/dev/null 2>&1; then
        local candidate simulate
        candidate=$(apt-cache policy wireguard-tools | awk '/Candidate:/ && candidate == "" {candidate=$2} END {print candidate}')
        [[ -n $candidate && $candidate != '(none)' ]] || fail 'Sem candidato APT wireguard-tools'
        simulate=$(apt-get -s --no-install-recommends install wireguard-tools 2>/dev/null) || fail 'Simulacao APT falhou'
        if grep -q '^Remv ' <<< "$simulate"; then
            fail 'APT iria remover pacotes instalados'
        fi
    fi
}
preflight() {
    check_host
    printf 'GALERA_PHASE1A_PREFLIGHT=PASS\nHOST=%s\n' "$HOST"
    if command -v wg >/dev/null 2>&1; then
        echo 'WG_TOOLS=INSTALLED'
    else
        echo 'WG_TOOLS=INSTALL_REQUIRED'
    fi
    if [[ -e $KEY_FILE ]]; then echo 'WG_KEY=EXISTS'; else echo 'WG_KEY=NOT_YET_CREATED'; fi
    echo 'GALERA_NETWORK_CHANGED=NO'
}
run() {
    preflight
    local before_pid after_pid
    if [[ $HOST == dmr-portugal ]]; then
        before_pid=$(systemctl show -P MainPID mariadb.service)
    else
        before_pid=$(systemctl show -P MainPID brandmeister@default.service)
    fi
    exec 9>/run/lock/hamdmr-galera-phase1a.lock
    flock -n 9 || fail 'Outra preparacao Galera em execucao'
    if ! command -v wg >/dev/null 2>&1; then
        state changed apt 'A iniciar instalacao do pacote wireguard-tools'
        apt-get install -y --no-install-recommends wireguard-tools || fail 'Instalacao APT falhou'
    fi
    command -v wg >/dev/null || fail 'Ferramenta wg nao instalada'
    state changed keygen 'Preparacao local de chaves WireGuard (sem rede)'
    install -d -o root -g root -m 0700 "$KEY_DIR"
    [[ ! -L $KEY_DIR && ! -L $KEY_FILE && ! -L $PUB_FILE ]] || fail 'Symlink inesperado apos instalacao'
    if [[ ! -e $KEY_FILE ]]; then
        local temp_key
        temp_key=$(mktemp "$KEY_DIR/.node.key.XXXXXXXX")
        chmod 0600 "$temp_key"
        wg genkey > "$temp_key" || fail 'Nao foi possivel criar chave privada'
        wg pubkey < "$temp_key" >/dev/null || fail 'Chave gerada nao passou validacao'
        mv -n "$temp_key" "$KEY_FILE" || fail 'Falha ao guardar chave privada'
        [[ -f $KEY_FILE ]] || fail 'Chave nao criada'
    fi
    local public
    public=$(wg pubkey < "$KEY_FILE") || fail 'Nao foi possivel derivar chave publica'
    if [[ -f $PUB_FILE && $(cat "$PUB_FILE") != "$public" ]]; then fail 'Chave publica preexistente nao corresponde a privada'; fi
    printf '%s\n' "$public" > "$PUB_FILE"
    chmod 0600 "$PUB_FILE" "$KEY_FILE"
    if [[ $HOST == dmr-portugal ]]; then
        systemctl is-active --quiet mariadb.service || fail 'MariaDB deixou de estar ativo'
        systemctl is-active --quiet mariadb.socket || fail 'Socket MariaDB deixou de estar ativo'
        after_pid=$(systemctl show -P MainPID mariadb.service)
    else
        systemctl is-active --quiet brandmeister@default.service || fail 'BrandMeister deixou de estar ativo'
        after_pid=$(systemctl show -P MainPID brandmeister@default.service)
    fi
    [[ "$before_pid" == "$after_pid" ]] || fail 'PID do servico critico foi alterado durante a preparacao; investigar'
    state changed completed 'Ferramentas e chave locais preparadas; nenhum servico de rede ou radio alterado'
    printf '\nGALERA_PHASE1A=OK\nHOST=%s\nWG_PUBLIC_KEY=%s\n' "$HOST" "$public"
    printf 'WG_PRIVATE_KEY_EXPORTED=NO\nWG_INTERFACE_CREATED=NO\nFIREWALL_CHANGED=NO\nGALERA_SQL_CHANGED=NO\n'
    printf 'NEXT_STEP=Collect the three public keys to configure private mesh\n'
}
case "$MODE" in
    --preflight|--check) preflight ;;
    --shadow-preflight) preflight; echo 'HAMDMR_SHADOW_PREFLIGHT=PASS' ;;
    --run) run ;;
    *) fail "Modo nao suportado: $MODE" ;;
esac
