#!/usr/bin/env bash
# HAMDMR Â· Galera Cluster de 3 nos Â· Fase 0 Â· Auditoria exclusivamente de leitura
# 2026-10-19 Â· r1 Â· COMPATIVEL: Debian 13 / MariaDB 11.8
# Nao instala pacotes, nao escreve ficheiros e nao altera unidades ou firewall.
set -u
export LC_ALL=C SYSTEMD_PAGER=cat PAGER=cat SYSTEMD_COLORS=0

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf '%s\n' 'Uso: bash hamdmr-galera-phase0-readiness-r1.sh' \
    'Auditoria de leitura em dmr-portugal, hamdmr ou bm2681.'
  exit 0
fi
if (($#)); then echo 'ERRO: argumentos nao esperados; usar --help' >&2; exit 2; fi

HOST=$(hostname -s 2>/dev/null || echo unknown)
case "$HOST" in
  hamdmr|bm2681|dmr-portugal) ;;
  *) echo "ERRO: host desconhecido ($HOST); nada executado" >&2; exit 2 ;;
esac
if [[ $(id -u) -ne 0 ]]; then
  echo 'ERRO: executar como root para consulta completa' >&2; exit 2
fi

section() { printf '\n=== %s ===\n' "$1"; }
kv() { printf '%-30s %s\n' "$1" "$2"; }
activity() { systemctl is-active "$1" 2>/dev/null || true; }
pkg() {
  local name="$1" installed candidate
  installed=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)
  candidate=$(apt-cache policy "$name" 2>/dev/null | awk '/Candidate:/ {print $2;exit}')
  kv "$name" "instalado=${installed:-nao} candidato=${candidate:-desconhecido}"
}

printf 'HAMDMR_GALERA_PHASE0=r1\n'
kv HOST "$HOST"
kv UTC "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kv KERNEL "$(uname -r)"
kv ARCH "$(uname -m)"
kv ROOT_UID "$(id -u)"

section 'VERSOES DISPONIVEIS / INSTALADAS'
for p in mariadb-server galera-4 mariadb-backup socat wireguard-tools; do pkg "$p"; done

section 'RECURSOS'
kv CPU_N "$(nproc)"
free -h | sed -n '1,3p'
df -h / /var/lib 2>/dev/null | awk 'NR==1 || !seen[$1]++'
kv TIME_NTP "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo desconhecido)"
kv TIME_ZONE "$(timedatectl show -p Timezone --value 2>/dev/null || echo desconhecido)"
kv VIRT "$(systemd-detect-virt 2>/dev/null || echo none)"

section 'INTERFACES E ROTAS PARA PEERS CONHECIDOS'
ip -br -4 addr show 2>/dev/null || true
for peer in 193.137.237.12 185.11.166.30; do
  ip route get "$peer" 2>/dev/null | head -1 || true
done

section 'PORTAS DE BASES E REPLICACAO EM ESCUTA'
if command -v ss >/dev/null 2>&1; then
  ss -H -lntup 2>/dev/null | awk '$5 ~ /:(3306|3307|3308|4444|4567|4568)$/ {print}' | head -30
else
  echo 'ss indisponivel'
fi

section 'UNIDADES MARIADB'
for svc in mariadb.service mariadb.socket mariadb@galera.service mariadb@galera.socket dmr-mariadb-firewall.service; do
  a=$(activity "$svc")
  e=$(systemctl is-enabled "$svc" 2>/dev/null || true)
  kv "$svc" "active=${a:-nao} enabled=${e:-nao}"
done

section 'TEMPLATE MULTI-INSTANCE / SYSTEMD'
if systemctl cat mariadb@.service >/dev/null 2>&1; then
  systemctl show mariadb@galera.service -p FragmentPath -p DropInPaths --no-pager 2>/dev/null || true
else
  echo 'mariadb@.service nao disponivel (pacote ainda nao instalado)'
fi

section 'SISTEMA DE FICHEIROS E INODES'
df -ih /var/lib 2>/dev/null | head -2 || true
findmnt -T /var/lib -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | head -2 || true

section 'PRESSAO I/O (CONTEXTO, NAO BENCHMARK)'
if [[ -r /proc/pressure/io ]]; then cat /proc/pressure/io; fi
for path in /sys/fs/cgroup/system.slice/system-brandmeister.slice/brandmeister@default.service/io.pressure; do
  if [[ -r "$path" ]]; then
    echo 'BrandMeister io.pressure:'
    cat "$path"
  fi
done

section 'INSTANCIA SQL EXISTENTE (SOMENTE LEITURA)'
if [[ "$HOST" == 'dmr-portugal' ]]; then
  if command -v mariadb >/dev/null 2>&1; then
    mariadb --batch --skip-column-names -e \
      "SELECT CONCAT('version=', @@version, ';port=', @@port, ';bind=', @@bind_address, ';log_bin=', @@log_bin, ';secure_transport=', @@require_secure_transport);" 2>/dev/null \
      || echo 'INFO: consulta SQL local indisponivel; conferir socket/credenciais locais'
    mariadb --batch --skip-column-names -e \
      "SELECT CONCAT('engine=',engine,';tables=',COUNT(*)) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys') GROUP BY engine ORDER BY engine;" 2>/dev/null \
      || echo 'INFO: consulta de engines indisponivel'
  else
    echo 'INFO: cliente mariadb nao instalado'
  fi
  if [[ -r /usr/local/sbin/dmr-mariadb-firewall ]]; then
    echo 'Firewall MariaDB propria: script existente, nao alterado'
  fi
fi

section 'SERVICOS EM FALHA'
systemctl --failed --no-pager --plain 2>/dev/null | head -16 || true

section 'RESULTADO'
echo 'PHASE0_READ_ONLY=OK'
echo 'PHASE0_CHANGES=NONE'
echo 'PHASE0_INSTALL_AUTHORIZED=NO'
