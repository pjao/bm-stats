#!/usr/bin/env bash
# DMR-PORTUGAL: move NGINX/VTS/FPM/cache SQL history consumers to the local Galera Unix socket.
# --check = read-only. --apply = timed collector pause, final dump, Galera-only replacement,
#              atomic six-file patch, restore timer states. Never modifies original 3306 DB.
set -Eeuo pipefail
umask 077
export SYSTEMD_PAGER=cat PAGER=cat SYSTEMD_COLORS=0 MYSQL_PWD=''
MODE=${1:---check}
[[ $# -le 1 && ( $MODE == --check || $MODE == --apply ) ]] || { echo 'USAGE: script --check|--apply' >&2;exit 2; }
[[ $(id -u) == 0 && $(hostname -s) == dmr-portugal ]] || { echo 'BLOCKED=ONLY_ROOT_ON_DMR_PORTUGAL' >&2;exit 2; }
OLD=/run/mysqld/mysqld.sock
NEW=/run/hamdmr-galera/mysqld.sock
DB=nginx_vts_history
DIR=/root/backups
FILES=(
  /usr/local/libexec/dmr-nginx-vts-history.py
  /usr/local/libexec/dmr-vts-history-exporter.py
  /usr/local/libexec/dmr-fpm-history.py
  /usr/local/libexec/dmr-fpm-history-exporter.py
  /usr/local/libexec/dmr-cache-history/cache_ingest.py
  /usr/local/libexec/dmr-cache-history/cache_export.py
)
TIMERS=(
  dmr-nginx-vts-history.timer
  dmr-vts-history-export.timer
  dmr-fpm-history.timer
  dmr-fpm-history-export.timer
  dmr-cache-history.timer
)
SERVICES=(
  dmr-nginx-vts-history.service
  dmr-vts-history-export.service
  dmr-fpm-history.service
  dmr-fpm-history-export.service
  dmr-cache-history.service
)
fail(){ echo "BLOCKED=$*" >&2; exit 2; }
oldsql(){ mariadb --no-defaults --protocol=socket --socket="$OLD" -N -B -e "$1"; }
newsql(){ mariadb --no-defaults --protocol=socket --socket="$NEW" -N -B -e "$1"; }
for cmd in mariadb mariadb-dump gzip python3 sha256sum systemctl mktemp cp stat tar; do
 command -v "$cmd" >/dev/null || fail "MISSING_COMMAND_$cmd"
done
[[ -S "$OLD" && -S "$NEW" && -d "$DIR" ]] || fail 'SOCKET_OR_BACKUP_DIR_MISSING'
[[ $(oldsql 'SELECT @@port') == 3306 && $(newsql 'SELECT @@port') == 3307 ]] || fail 'WRONG_DATABASE_PORTS'
[[ $(newsql 'SELECT @@wsrep_on') == 1 ]] || fail 'GALERA_DISABLED'
for entry in 'wsrep_cluster_status Primary' 'wsrep_ready ON' 'wsrep_cluster_size 3' 'wsrep_local_state_comment Synced'; do
 read -r item want <<< "$entry"
 got=$(newsql "SHOW GLOBAL STATUS LIKE '$item'" | awk '{print $2}')
 [[ "$got" == "$want" ]] || fail "GALERA_NOT_READY_$item=$got"
done
for instance in old new; do
  if [[ $instance == old ]];then query=oldsql;else query=newsql;fi
  [[ $($query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE'") == 11 ]] || fail "TABLES_MISSING_$instance"
  [[ $($query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'") == 0 ]] || fail "NON_INNODB_$instance"
  [[ $($query "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$DB' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')") == 0 ]] || fail "MISSING_PRIMARY_KEY_$instance"
done
for name in "${TIMERS[@]}";do
 systemctl cat "$name" >/dev/null 2>&1 || fail "UNKNOWN_TIMER_$name"
 systemctl is-active --quiet "$name" || fail "TIMER_NOT_ACTIVE_$name"
done
for name in "${SERVICES[@]}";do
 systemctl cat "$name" >/dev/null 2>&1 || fail "UNKNOWN_SERVICE_$name"
 user=$(systemctl show -P User "$name")
 [[ -z "$user" || "$user" == root ]] || fail "SERVICE_NONROOT_$name:$user"
done
WORK=$(mktemp -d /tmp/dmr-vts-galera-preflight.XXXXXXXX)
OUT=''
CHANGED=0
PAUSED=0
cleanup(){
 local rc=$?
 trap - EXIT
 if (( rc != 0 ));then
  if (( CHANGED ));then
   for i in "${!FILES[@]}";do
    [[ -f $OUT/originals/$i.py ]] && cp -a -- "$OUT/originals/$i.py" "${FILES[$i]}" || true
   done
   echo 'CODE_ROLLBACK=ATTEMPTED_OLD_3306_SOCKET'
  fi
  if (( PAUSED ));then
   for timer in "${TIMERS[@]}";do systemctl start "$timer" || true; done
   echo 'TIMER_RECOVERY=ATTEMPTED'
  fi
  echo 'CUTOVER=INCOMPLETE'
  [[ -z $OUT ]] || echo "BACKUP=$OUT"
 fi
 rm -rf -- "$WORK"
 exit "$rc"
}
trap cleanup EXIT
python3 - "$WORK" "$NEW" "${FILES[@]}" <<'PY'
import ast,os,pathlib,re,stat,sys
stage,socket,*files=sys.argv[1:]
pat=re.compile(r"(?P<quote>['\"])--protocol=socket(?P=quote)")
for i,name in enumerate(files):
    f=pathlib.Path(name)
    if not f.is_file() or f.is_symlink():raise SystemExit('BLOCKED=FILE_NOT_REGULAR_'+name)
    raw=f.read_bytes()
    data=raw.decode('utf-8')
    matches=list(pat.finditer(data))
    if len(matches)!=1 or '--socket=' in data:raise SystemExit('BLOCKED=UNEXPECTED_SOCKET_LITERAL_'+name)
    tree=ast.parse(data,filename=name)
    lists=[n for n in ast.walk(tree) if isinstance(n,(ast.List,ast.Tuple)) and any(isinstance(x,ast.Constant) and x.value=='--protocol=socket' for x in n.elts)]
    if len(lists)!=1:raise SystemExit('BLOCKED=UNEXPECTED_MYSQL_ARGUMENT_LIST_'+name)
    m=matches[0];q=m.group('quote')
    new=data[:m.end()]+','+q+'--socket='+socket+q+data[m.end():]
    compile(new,name,'exec')
    dest=pathlib.Path(stage)/f'{i}.py'
    dest.write_bytes(new.encode('utf-8'))
    os.chmod(dest,stat.S_IMODE(f.stat().st_mode))
    print('PATCH_READY='+name)
print('PATCH_COUNT=6')
PY
[[ $(newsql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$DB' AND ID<>CONNECTION_ID()") == 0 ]] || fail 'GALERA_DB_ALREADY_IN_USE'
echo 'PREFLIGHT=OK'
echo "GALERA_SOCKET=$NEW"
[[ $MODE == --apply ]] || { echo 'CHANGES_APPLIED=NO'; exit 0; }
[[ $(df -B1 --output=avail "$DIR" | tail -1) -ge 268435456 ]] || fail 'BACKUP_VOLUME_LOW'
OUT=$(mktemp -d "$DIR/dmr-vts-galera-cutover-20261020-XXXXXXXX")
chmod 700 "$OUT"
mkdir -m 700 "$OUT/originals"
for i in "${!FILES[@]}"; do cp -a -- "${FILES[$i]}" "$OUT/originals/$i.py"; done
sha256sum "${FILES[@]}" > "$OUT/program-baseline.sha256"
echo "BACKUP=$OUT"
# Pause ALL five collection/export timers; let any oneshot already running finish naturally.
PAUSED=1
for timer in "${TIMERS[@]}";do systemctl stop "$timer";done
for i in $(seq 1 50);do
 running=0
 for service in "${SERVICES[@]}";do
  systemctl is-active --quiet "$service" && running=$((running+1))
 done
 ((running==0)) && break
 sleep 1
done
((running==0)) || fail 'COLLECTOR_SERVICES_STILL_RUNNING'
[[ $(newsql "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$DB' AND ID<>CONNECTION_ID()") == 0 ]] || fail 'GALERA_DB_BECAME_ACTIVE'
# Recheck every source file against the validated baseline, avoiding a concurrent code deployment.
sha256sum -c --status "$OUT/program-baseline.sha256" || fail 'SOURCE_CODE_CHANGED_DURING_PREFLIGHT'
# Consistent InnoDB snapshot, source MariaDB stays untouched.
mariadb-dump --no-defaults --protocol=socket --socket="$OLD" \
 --single-transaction --quick --hex-blob --skip-comments \
 --skip-add-locks --skip-disable-keys --skip-add-drop-table "$DB" \
 | gzip -1 > "$OUT/source-final.sql.gz"
gzip -t "$OUT/source-final.sql.gz" && [[ -s "$OUT/source-final.sql.gz" ]] || fail 'SOURCE_SNAPSHOT_FAILED'
sha256sum "$OUT/source-final.sql.gz" >> "$OUT/snapshot-sha256.txt"
echo 'FINAL_SOURCE_SNAPSHOT=OK'
read -r charset collation <<< "$(oldsql "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB'")"
[[ $charset =~ ^[A-Za-z0-9_]+$ && $collation =~ ^[A-Za-z0-9_]+$ ]] || fail 'UNSAFE_CHARSET'
# Target has no production consumers and will be rebuilt from this final snapshot.
newsql "DROP DATABASE \`$DB\`; CREATE DATABASE \`$DB\` CHARACTER SET $charset COLLATE $collation;"
gzip -dc "$OUT/source-final.sql.gz" | mariadb --no-defaults --protocol=socket --socket="$NEW" "$DB"
[[ $(newsql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE'") == 11 ]] || fail 'IMPORTED_TABLE_COUNT_WRONG'
[[ $(newsql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'") == 0 ]] || fail 'IMPORTED_NON_INNODB'
[[ $(newsql "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$DB' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')") == 0 ]] || fail 'IMPORTED_MISSING_PRIMARY_KEYS'
while IFS= read -r table;do
 [[ $table =~ ^[A-Za-z0-9_]+$ ]] || fail 'INVALID_TABLE_NAME'
 a=$(oldsql "SELECT COUNT(*) FROM \`$DB\`.\`$table\`")
 b=$(newsql "SELECT COUNT(*) FROM \`$DB\`.\`$table\`")
 [[ $a == "$b" ]] || fail "ROW_COUNT_MISMATCH_$table:$a/$b"
done < <(newsql "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME")
echo 'GALERA_FINAL_SYNC=OK TABLES=11'
CHANGED=1
python3 - "$WORK" "${FILES[@]}" <<'PY'
import os,pathlib,stat,sys,tempfile
root,*files=sys.argv[1:]
for i,name in enumerate(files):
    p=pathlib.Path(name)
    st=p.stat()
    fd,tmp=tempfile.mkstemp(prefix='.galera-vts-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write((pathlib.Path(root)/f'{i}.py').read_bytes());out.flush();os.fsync(out.fileno())
        os.chmod(tmp,stat.S_IMODE(st.st_mode))
        os.chown(tmp,st.st_uid,st.st_gid)
        os.replace(tmp,name)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
    print('PATCH_APPLIED='+name)
PY
# Critical: prove every modified program contains exactly the Galera socket and compiles.
for file in "${FILES[@]}";do
 python3 - "$file" "$NEW" <<'PY'
import ast,pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
assert s.count('--socket='+sys.argv[2])==1
ast.parse(s)
PY
done
for timer in "${TIMERS[@]}";do systemctl start "$timer";done
PAUSED=0
CHANGED=0
trap - EXIT
rm -rf -- "$WORK"
cat > "$OUT/ROLLBACK.txt" <<EOF
If necessary, stop the five collector timers, copy original Python files from $OUT/originals/ back into their six respective paths, and restart the five timers.
IMPORTANT: Original MariaDB 3306 data remain unchanged. After cutover, new events written to Galera would be lost on code-only rollback; analyze first.
EOF
echo 'CUTOVER=OK'
echo 'MYSQL_TARGET=LOCAL_GALERA_SOCKET'
echo 'SOURCE_3306=UNCHANGED'
echo "BACKUP=$OUT"
for timer in "${TIMERS[@]}";do printf 'TIMER=%s STATE=%s\n' "$timer" "$(systemctl is-active "$timer")";done
