#!/usr/bin/env bash
# DMR-PORTUGAL Â· Materialize three FINAL SQL schemas from verified Galera stages.
# No production cutover, no credential changes, no writes on MariaDB legacy 3306,
# no process restarts. Does not delete stages. Stops if any final target exists.
set -Eeuo pipefail
umask 077
export MYSQL_PWD=''
export LC_ALL=C
GALERA=/run/hamdmr-galera/mysqld.sock
LEGACY=/run/mysqld/mysqld.sock
DATE_SUFFIX=_galera_stage_20261020
DATABASES=(dmr_stats nginx_vts_history osticket)
sql(){ mariadb --no-defaults --protocol=socket --socket="$GALERA" --batch --skip-column-names --execute="$1"; }
sqli(){ mariadb --no-defaults --protocol=socket --socket="$LEGACY" --batch --skip-column-names --execute="$1"; }
die(){ printf 'RESULT=BLOCKED REASON=%s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 && $(hostname -s) == dmr-portugal ]] || die 'Execute as root on dmr-portugal only'
[[ -S "$GALERA" && -S "$LEGACY" ]] || die 'Expected MariaDB sockets not found'
for cmd in mariadb mariadb-dump gzip df awk grep mktemp; do command -v "$cmd" >/dev/null || die "Missing $cmd"; done
[[ $(sql 'SELECT @@port') == 3307 && $(sqli 'SELECT @@port') == 3306 ]] || die 'Wrong instance ports'
[[ $(sql 'SELECT @@wsrep_on') == 1 ]] || die 'Not Galera'
[[ $(sql "SHOW GLOBAL STATUS LIKE 'wsrep_ready'" | awk '{print $2}') == ON ]] || die 'Galera not ready'
[[ $(sql "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'" | awk '{print $2}') == Primary ]] || die 'Galera not Primary'
[[ $(sql "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" | awk '{print $2}') == 3 ]] || die 'Cluster not at three nodes'
for db in "${DATABASES[@]}"; do
  stage="${db}${DATE_SUFFIX}"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$stage'") == 1 ]] || die "Stage missing: $stage"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db'") == 0 ]] || die "Final database already exists: $db. No overwrites allowed"
  n=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stage' AND TABLE_TYPE='BASE TABLE'")
  case "$db" in dmr_stats) expected=2;; nginx_vts_history) expected=11;; osticket) expected=144;; esac
  [[ $n == "$expected" ]] || die "Unexpected table count $db = $n, expected $expected"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stage' AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB'") == 0 ]] || die "Non-InnoDB tables in $stage"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$stage' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')") == 0 ]] || die "Tables without PK in $stage"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA='$stage' AND REFERENCED_TABLE_SCHEMA IS NOT NULL AND REFERENCED_TABLE_SCHEMA <> '$stage'") == 0 ]] || die "Cross-schema FK detected in $stage"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$stage'") == 0 ]] || die "Triggers found in $stage"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='$stage'") == 0 ]] || die "Views found in $stage"
  echo "PREFLIGHT_OK=$db TABLES=$n STAGE=$stage"
done
ROOT=/root/backups
[[ -d "$ROOT" ]] || die 'Backup root absent'
[[ $(df --output=avail -B1 "$ROOT" | tail -1) -ge 268435456 ]] || die 'Less than 256MiB disk available'
WORK=$(mktemp -d "$ROOT/galera-final-schemas-20261020-XXXXXXXX")
chmod 700 "$WORK"
trap 'rc=$?; if ((rc)); then echo "RESULT=INCOMPLETE; see $WORK; original 3306 remains unchanged" >&2; fi' EXIT
for db in "${DATABASES[@]}"; do
  stage="${db}${DATE_SUFFIX}"
  echo "=== FINAL SCHEMA PREPARATION $stage -> $db ==="
  IFS=$'\t' read -r cs coll <<< "$(sql "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$stage'")"
  [[ $cs =~ ^[a-zA-Z0-9_]+$ && $coll =~ ^[a-zA-Z0-9_]+$ ]] || die "Unexpected charset/collation $db"
  echo "BEGIN_DUMP=$db"
  # InnoDB-only staging allows transaction-consistent dump. Keep private compressed copy.
  mariadb-dump --no-defaults --protocol=socket --socket="$GALERA" \
     --single-transaction --quick --hex-blob --skip-add-locks --skip-disable-keys \
     --skip-add-drop-table --skip-comments --skip-triggers "$stage" | gzip -1 > "$WORK/$db.sql.gz"
  gzip -t "$WORK/$db.sql.gz" || die "Invalid dump of $db"
  echo "DUMP_OK=$db"
  sql "CREATE DATABASE \`$db\` CHARACTER SET $cs COLLATE $coll"
  gzip -dc "$WORK/$db.sql.gz" | mariadb --no-defaults --protocol=socket --socket="$GALERA" "$db"
  n=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_TYPE='BASE TABLE'")
  case "$db" in dmr_stats) expected=2;; nginx_vts_history) expected=11;; osticket) expected=144;; esac
  [[ $n == "$expected" ]] || die "Final table count mismatch for $db: $n"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB'") == 0 ]] || die "Final non-InnoDB tables in $db"
  [[ $(sql "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$db' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')") == 0 ]] || die "Final missing primary keys for $db"
  checked=0
  while IFS= read -r table; do
    [[ $table =~ ^[a-zA-Z0-9_]+$ ]] || die "Unexpected table name in $stage"
    from_n=$(sql "SELECT COUNT(*) FROM \`$stage\`.\`$table\`")
    to_n=$(sql "SELECT COUNT(*) FROM \`$db\`.\`$table\`")
    [[ $from_n == "$to_n" ]] || die "Data row count mismatch for $db.$table: $from_n vs $to_n"
    ((checked+=1))
  done < <(sql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$stage' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME")
  [[ $checked == "$expected" ]] || die "Validation incomplete for $db"
  echo "FINAL_SCHEMA_OK=$db TABLES=$n ENGINE=InnoDB PK=YES EXACT_ROW_COUNTS=OK"
done
trap - EXIT
echo 'RESULT=FINAL_SCHEMAS_READY'
echo 'APPLICATION_CONNECTIONS=UNCHANGED'
echo 'ORIGINAL_3306=UNCHANGED'
echo 'GALERA_3307=FINAL_SCHEMAS_CREATED'
echo "SQL_BACKUPS=$WORK"
echo 'ACTION_NEXT=Application-aware cutover with separate final sync and grants'
