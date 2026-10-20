#!/usr/bin/env bash
# DMR-PORTUGAL · isolated Galera staging for three existing MariaDB applications.
# NEVER modifies the original databases or application configurations.
set -Eeuo pipefail
umask 077
export MYSQL_PWD=''  # do not inherit MYSQL_PWD from an interactive shell

LEGACY=/run/mysqld/mysqld.sock
GALERA=/run/hamdmr-galera/mysqld.sock
TARGETS=(dmr_stats nginx_vts_history osticket)
SUFFIX=_galera_stage_20261020
LOGROOT=/root/backups
TS=$(date +%Y%m%d-%H%M%S)
OUT="$LOGROOT/galera-sql-stage-$TS"

sqli() { mariadb --no-defaults --protocol=socket --socket="$LEGACY" --batch --skip-column-names --execute="$1"; }
sqlg() { mariadb --no-defaults --protocol=socket --socket="$GALERA" --batch --skip-column-names --execute="$1"; }
fail() { echo "STAGE_RESULT=BLOCKED"; echo "REASON=$*"; exit 1; }

[[ "$(id -u)" == 0 ]] || fail "root required"
[[ "$(hostname -s)" == dmr-portugal ]] || fail "wrong host"
[[ -S "$LEGACY" && -S "$GALERA" ]] || fail "database sockets missing"
command -v mariadb-dump >/dev/null || fail "mariadb-dump missing"
command -v python3 >/dev/null || fail "python3 missing"
[[ "$(sqlg 'SELECT @@wsrep_on')" == 1 ]] || fail 'not Galera'
[[ "$(sqlg "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'" | awk '{print $2}')" == Primary ]] || fail 'cluster not primary'
[[ "$(sqlg "SHOW GLOBAL STATUS LIKE 'wsrep_ready'" | awk '{print $2}')" == ON ]] || fail 'Galera not ready'
[[ "$(sqlg "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" | awk '{print $2}')" == 3 ]] || fail 'not all three Galera nodes present'
[[ "$(sqli 'SELECT @@port')" == 3306 ]] || fail 'legacy instance not on 3306'
[[ "$(sqlg 'SELECT @@port')" == 3307 ]] || fail 'Galera instance not on 3307'
[[ $(df --output=avail -B1 "$LOGROOT" | tail -1) -ge 536870912 ]] || fail 'Less than 512MiB disk free in backups volume'

for name in "${TARGETS[@]}"; do
    [[ $(sqli "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$name'") == 1 ]] || fail "legacy database $name missing"
    stage="${name}${SUFFIX}"
    [[ $(sqlg "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$stage'") == 0 ]] || fail "Galera $stage already exists; this script does not overwrite it"
    [[ $(sqli "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$name' AND TABLE_TYPE='VIEW'") == 0 ]] || fail "views present in $name; manual review first"
    [[ $(sqli "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$name'") == 0 ]] || fail "triggers present in $name; manual review first"
    [[ $(sqli "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='$name'") == 0 ]] || fail "stored routines present in $name; manual review first"
    [[ $(sqli "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='$name'") == 0 ]] || fail "events present in $name; manual review first"
    missing=$(sqli "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$name' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')")
    [[ "$missing" == 0 ]] || fail "$name has $missing tables without PK"
    case "$name" in
      dmr_stats) expected=2 ;;
      nginx_vts_history) expected=11 ;;
      osticket) expected=144 ;;
    esac
    actual=$(sqli "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$name' AND TABLE_TYPE='BASE TABLE'")
    [[ "$actual" == "$expected" ]] || fail "Unexpected table count in $name: $actual expected $expected"
    echo "PREFLIGHT=$name TABLES=$actual PRIMARY_KEYS=OK TARGET_AVAILABLE=YES"
done

mkdir -p -m 700 "$OUT"
chmod 700 "$OUT"
printf '%s\n' 'DMR-PORTUGAL · ORIGINAL_MARIADB_3306_UNCHANGED · Galera isolated stage' > "$OUT/README.txt"
echo "BACKUP_DIRECTORY=$OUT"

db_current=''
trap 'rc=$?; if ((rc)); then echo "STAGE_RESULT=INCOMPLETE"; echo "LAST_DATABASE=${db_current:-none}"; echo "BACKUP_DIRECTORY=$OUT"; echo "SOURCE_DATABASES=UNCHANGED"; echo "APPLICATION_CONFIGS=UNCHANGED"; fi' EXIT

for name in "${TARGETS[@]}"; do
    db_current="$name"
    stage="${name}${SUFFIX}"
    echo "=== COPYING $name -> $stage (original remains live) ==="

    charset=$(sqli "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$name'")
    read -r cs coll <<<"$charset"
    [[ "$cs" =~ ^[a-zA-Z0-9_]+$ && "$coll" =~ ^[a-zA-Z0-9_]+$ ]] || fail "unsafe/unexpected charset or collation for $name"

    compressed="$OUT/${name}.sql.gz"
    mariadb-dump --no-defaults --protocol=socket --socket="$LEGACY" \
      --quick --lock-tables --hex-blob --skip-add-locks --skip-disable-keys \
      --skip-add-drop-table --skip-comments "$name" | gzip -1 > "$compressed"
    gzip -t "$compressed"
    [[ -s "$compressed" ]] || fail "empty dump of $name"
    echo "SOURCE_DUMP=OK FILE=$compressed"

    converted="$OUT/${name}.converted.sql"
    python3 - "$compressed" "$converted" <<'PY'
import gzip, re, sys
rawfile, target = sys.argv[1:]
count = 0
inside_create = False
with gzip.open(rawfile, 'rb') as infile, open(target, 'wb') as outfile:
    for line in infile:
        if line.startswith(b'CREATE TABLE '):
            inside_create = True
        if inside_create and re.match(rb'^\)\s*ENGINE\s*=\s*', line, re.I):
            line, n = re.subn(rb'\bENGINE\s*=\s*MyISAM\b', b'ENGINE=InnoDB', line, count=1, flags=re.I)
            count += n
            inside_create = False
        outfile.write(line)
print('DDL_MYISAM_CONVERSIONS='+str(count))
PY
    sqlg "CREATE DATABASE \`$stage\` CHARACTER SET $cs COLLATE $coll"
    echo "STAGE_DATABASE_CREATED=$stage"
    mariadb --no-defaults --protocol=socket --socket="$GALERA" "$stage" < "$converted"

    source_count=$(sqli "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$name' AND TABLE_TYPE='BASE TABLE'")
    dest_count=$(sqlg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stage' AND TABLE_TYPE='BASE TABLE'")
    [[ "$source_count" == "$dest_count" ]] || fail "table count mismatch $name source $source_count destination $dest_count"
    noninnodb=$(sqlg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stage' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'")
    [[ "$noninnodb" == 0 ]] || fail "$name destination contains non InnoDB tables"
    missingpk=$(sqlg "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$stage' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')")
    [[ "$missingpk" == 0 ]] || fail "missing primary keys $stage"

    # Snapshot stays on disk as a compressed copy, not the temporary converted SQL.
    rm -f -- "$converted"
    echo "STAGE_OK=$stage TABLES=$dest_count INNODB=YES PK=YES"
done

trap - EXIT
echo 'STAGE_RESULT=READY'
echo 'ORIGINAL_MARIADB_3306=UNCHANGED'
echo 'APPLICATION_CONNECTIONS=UNCHANGED'
echo 'GALERA_SQL_STAGES=3'
echo "BACKUP_DIRECTORY=$OUT"
echo 'ACTION_NEXT=Prepare application-aware cutover; DO NOT SWITCH CONNECTIONS YET'
