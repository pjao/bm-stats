#!/usr/bin/env bash
# DMR-PORTUGAL osTicket 3306 -> Galera local 127.0.0.1:3307.
# --check only reads; --apply changes Galera osTicket and ost-config.php ONLY.
# Does not stop/restart MariaDB, PHP, Nginx, Apache or any BrandMeister services.
set -Eeuo pipefail
umask 077
export MYSQL_PWD=''
MODE="${1:---check}"
[[ "$MODE" == --check || "$MODE" == --apply ]] || { echo 'USAGE=--check|--apply'; exit 2; }
[[ $(id -u) == 0 && $(hostname -s) == dmr-portugal ]] || { echo 'BLOCKED=ONLY_DMR_PORTUGAL_ROOT'; exit 2; }
LEG=/run/mysqld/mysqld.sock
GAL=/run/hamdmr-galera/mysqld.sock
CFG=/var/www/suporte.brandmeister.pt/include/ost-config.php
DB=osticket
USER=ost_galera
BACKROOT=/root/backups
STAGE=osticket_galera_stage_20261020
for cmd in mariadb mariadb-dump python3 php openssl gzip sha256sum awk install; do
 command -v "$cmd" >/dev/null || { echo "BLOCKED=MISSING_$cmd"; exit 2; }
done
[[ -S "$LEG" && -S "$GAL" && -f "$CFG" && ! -L "$CFG" && -d "$BACKROOT" ]] || { echo 'BLOCKED=SOCKET_CONFIG_OR_BACKUP_MISSING'; exit 2; }
sl(){ mariadb --no-defaults --protocol=socket --socket="$LEG" --batch --skip-column-names -e "$1"; }
sg(){ mariadb --no-defaults --protocol=socket --socket="$GAL" --batch --skip-column-names -e "$1"; }
blocked(){ printf 'BLOCKED=%s\n' "$1" >&2; exit 2; }
[[ $(sl 'SELECT @@port') == 3306 && $(sg 'SELECT @@port') == 3307 ]] || blocked 'PORT_NOT_EXPECTED'
[[ $(sg 'SELECT @@wsrep_on') == 1 ]] || blocked 'GALERA_OFF'
for pair in 'wsrep_cluster_status Primary' 'wsrep_ready ON' 'wsrep_cluster_size 3' 'wsrep_local_state_comment Synced'; do
 read -r var expected <<< "$pair"
 [[ $(sg "SHOW GLOBAL STATUS LIKE '$var'" | awk '{print $2}') == "$expected" ]] || blocked "CLUSTER_NOT_READY_$var"
done
[[ $(sl "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE'") == 144 ]] || blocked 'SOURCE_TABLE_COUNT'
[[ $(sg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE'") == 144 ]] || blocked 'TARGET_TABLE_COUNT'
[[ $(sg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$STAGE' AND TABLE_TYPE='BASE TABLE'") == 144 ]] || blocked 'STAGE_TABLE_COUNT'
[[ $(sg "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$DB' AND ID<>CONNECTION_ID()") == 0 ]] || blocked 'TARGET_DB_ALREADY_IN_USE'
[[ $(sl "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'") == 0 ]] || blocked 'SOURCE_NOT_INNODB'
[[ $(sl "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='$DB'") == 0 ]] || blocked 'SOURCE_TRIGGERS_REQUIRE_REVIEW'
[[ $(sg "SELECT COUNT(*) FROM mysql.user WHERE User='$USER' AND Host IN ('127.0.0.1','localhost')") == 0 ]] || blocked 'GALERA_ACCOUNT_ALREADY_EXISTS'
php -l "$CFG" >/dev/null || blocked 'PHP_CONFIG_INVALID'
python3 - "$CFG" <<'PY'
import re,sys
p=sys.argv[1]
s=open(p).read()
for key in ('DBHOST','DBNAME','DBUSER','DBPASS'):
    matches=re.findall(r"(?m)^\s*define\s*\(\s*['\"]"+key+r"['\"]\s*,\s*(['\"])(.*?)\1\s*\)\s*;",s)
    if len(matches)!=1: raise SystemExit('BLOCKED=CONFIG_NOT_STATIC_'+key)
for k,v in [('DBHOST',('localhost','127.0.0.1')),('DBNAME',('osticket',))]:
    found=re.search(r"(?m)^\s*define\s*\(\s*['\"]"+k+r"['\"]\s*,\s*['\"]([^'\"]*)",s)
    if not found or found.group(1) not in v: raise SystemExit('BLOCKED=CONFIG_UNEXPECTED_'+k)
print('CONFIG_BASELINE=OK')
PY
# Make sure 3307 is reachable on local TCP; do not use legacy localhost socket.
python3 - <<'PY'
import socket
try:
 s=socket.create_connection(('127.0.0.1',3307),timeout=3);s.close()
except OSError:
 raise SystemExit('BLOCKED=GALERA_LOCAL_TCP_3307_UNAVAILABLE')
print('GALERA_LOCAL_TCP=OK')
PY
# Prove final schema is still an unmodified copy of the original snapshot.
while IFS= read -r table; do
 [[ $table =~ ^[A-Za-z0-9_]+$ ]] || blocked 'UNSAFE_TABLE_NAME'
 [[ $(sg "SELECT COUNT(*) FROM \`$DB\`.\`$table\`") == $(sg "SELECT COUNT(*) FROM \`$STAGE\`.\`$table\`") ]] || blocked "FINAL_DB_DIFFERS_FROM_STAGE_$table"
done < <(sg "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$STAGE' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME")
echo 'PREFLIGHT=OK'
echo 'LEGACY=3306/osticket'
echo 'GALERA_LOCAL=127.0.0.1:3307/osticket'
echo 'FINAL_STAGE_ROW_COUNTS=EQUAL'
echo 'SOURCE_TABLES=144'
[[ "$MODE" == --apply ]] || { echo 'CHANGES_APPLIED=NO'; exit 0; }
[[ $(df --output=avail -B1 "$BACKROOT" | tail -1) -ge 268435456 ]] || blocked 'BACKUP_DISK_LOW'
OUT=$(mktemp -d "$BACKROOT/osticket-galera-cutover-20261020-XXXXXXXX")
chmod 700 "$OUT"
cp -a -- "$CFG" "$OUT/ost-config.before.php"
openssl rand -hex 24 > "$OUT/galera-password.secret"
chmod 600 "$OUT/galera-password.secret"
SECRET=$(cat "$OUT/galera-password.secret")
[[ $SECRET =~ ^[0-9a-f]{48}$ ]] || blocked 'BAD_GENERATED_PASSWORD'
CONFIG_CHANGED=0
cleanup(){
 local rc=$?
 trap - EXIT
 if ((rc)); then
  if ((CONFIG_CHANGED)); then
   cp -a -- "$OUT/ost-config.before.php" "$CFG" || true
   echo 'CONFIG_ROLLBACK=ATTEMPTED'
  fi
  echo 'CUTOVER=INCOMPLETE'
  echo 'ORIGINAL_3306=UNCHANGED'
  echo "BACKUP=$OUT"
 fi
 exit "$rc"
}
trap cleanup EXIT
# Retain the source snapshot before touching the new target.
mariadb-dump --no-defaults --protocol=socket --socket="$LEG" --single-transaction \
 --quick --hex-blob --skip-add-locks --skip-disable-keys --skip-add-drop-table \
 --skip-comments "$DB" | gzip -1 > "$OUT/osticket-source-final.sql.gz"
gzip -t "$OUT/osticket-source-final.sql.gz"
[[ -s "$OUT/osticket-source-final.sql.gz" ]] || blocked 'SOURCE_DUMP_EMPTY'
sha256sum "$OUT/osticket-source-final.sql.gz" "$OUT/ost-config.before.php" > "$OUT/sha256sums.txt"
echo 'FINAL_SOURCE_SNAPSHOT=OK'
# Recheck no Galera app is using destination before replacing its staged data.
[[ $(sg "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$DB' AND ID<>CONNECTION_ID()") == 0 ]] || blocked 'TARGET_BECAME_ACTIVE'
read -r cs coll <<< "$(sg "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB'")"
[[ $cs =~ ^[A-Za-z0-9_]+$ && $coll =~ ^[A-Za-z0-9_]+$ ]] || blocked 'BAD_CHARSET'
# Only Galera database is replaced. Original 3306 remains untouched.
sg "DROP DATABASE \`$DB\`; CREATE DATABASE \`$DB\` CHARACTER SET $cs COLLATE $coll"
gzip -dc "$OUT/osticket-source-final.sql.gz" | mariadb --no-defaults --protocol=socket --socket="$GAL" "$DB"
[[ $(sg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE'") == 144 ]] || blocked 'IMPORT_TABLE_MISMATCH'
[[ $(sg "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'") == 0 ]] || blocked 'IMPORT_NON_INNODB'
[[ $(sg "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$DB' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')") == 0 ]] || blocked 'IMPORT_NO_PK'
# Match source row-counts table by table (nonzero divergence is an abort).
while IFS= read -r table; do
 [[ $table =~ ^[A-Za-z0-9_]+$ ]] || blocked 'BAD_TABLE'
 [[ $(sg "SELECT COUNT(*) FROM \`$DB\`.\`$table\`") == $(sl "SELECT COUNT(*) FROM \`$DB\`.\`$table\`") ]] || blocked "ROW_COUNT_DIFFERENCE_$table"
done < <(sg "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME")
echo 'GALERA_FINAL_SYNC=OK TABLES=144'
# Create accounts restricted to local host; no password appears in command-line args.
{
 printf "CREATE USER '%s'@'127.0.0.1' IDENTIFIED BY '%s';\n" "$USER" "$SECRET"
 printf "CREATE USER '%s'@'localhost' IDENTIFIED BY '%s';\n" "$USER" "$SECRET"
 for host in 127.0.0.1 localhost; do
  printf "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,DROP,REFERENCES,CREATE TEMPORARY TABLES,LOCK TABLES ON \`osticket\`.* TO '%s'@'%s';\n" "$USER" "$host"
 done
} | mariadb --no-defaults --protocol=socket --socket="$GAL" >/dev/null
# PHP direct app-shaped connection, including host:port parsing, before touching its config.
php -r '
mysqli_report(MYSQLI_REPORT_OFF);
$p=trim(file_get_contents($argv[1]));
$c=mysqli_init();
if (!@$c->real_connect("127.0.0.1:3307","ost_galera",$p,"osticket")) {fwrite(STDERR,"BLOCKED=PHP_MYSQLI_TCP\n");exit(1);}
$r=$c->query("SELECT @@port AS port, COUNT(*) AS n FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE=\"BASE TABLE\"");
if (!$r || ($a=$r->fetch_assoc())["port"]!=3307 || $a["n"]!=144) {fwrite(STDERR,"BLOCKED=MYSQLI_WRONG_DB\n");exit(1);}
echo "PHP_TCP=OK\n";
' "$OUT/galera-password.secret"
CONFIG_CHANGED=1
python3 - "$CFG" "$OUT/galera-password.secret" <<'PY'
import os,re,stat,sys,tempfile
path,secret=sys.argv[1:];text=open(path).read();passwd=open(secret).read().strip()
for key,value in (('DBHOST','127.0.0.1:3307'),('DBUSER','ost_galera'),('DBPASS',passwd)):
    pattern=r"(?m)^(\s*define\s*\(\s*['\"]"+key+r"['\"]\s*,\s*)['\"].*?['\"](\s*\)\s*;)"
    text,n=re.subn(pattern,lambda m:m.group(1)+"'"+value+"'"+m.group(2),text)
    if n!=1:raise SystemExit('BLOCKED=CONFIG_PATCH_'+key)
st=os.stat(path)
fd,tmp=tempfile.mkstemp(prefix='.osticket-galera-',dir=os.path.dirname(path))
try:
    with os.fdopen(fd,'w') as f:f.write(text);f.flush();os.fsync(f.fileno())
    os.chmod(tmp,stat.S_IMODE(st.st_mode));os.chown(tmp,st.st_uid,st.st_gid)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
PY
php -l "$CFG" >/dev/null
php -r '
require $argv[1];mysqli_report(MYSQLI_REPORT_OFF);
$c=@new mysqli(DBHOST,DBUSER,DBPASS,DBNAME);
if ($c->connect_errno){fwrite(STDERR,"APP_CONNECT=FAIL\n");exit(1);}
$r=$c->query("SELECT @@port AS port");
if (!$r || $r->fetch_assoc()["port"]!=3307){fwrite(STDERR,"APP_WRONG_PORT\n");exit(1);}
echo "APP_CONNECT=OK PORT=3307\n";
' "$CFG"
CONFIG_CHANGED=0
trap - EXIT
cat > "$OUT/ROLLBACK.txt" <<EOF
Restore config only (data added to Galera since cutover will not be mirrored back):
cp -a '$OUT/ost-config.before.php' '$CFG'
php -l '$CFG'
Original MariaDB 3306 unchanged. Galera DB has its own data after cutover.
EOF
printf 'CUTOVER=OK\nAPP=osTicket\nLOCAL_GALERA=127.0.0.1:3307\nORIGINAL_3306=UNCHANGED\nBACKUP=%s\n' "$OUT"
echo 'CHECK_WEB=https://suporte.brandmeister.pt/index.php'
