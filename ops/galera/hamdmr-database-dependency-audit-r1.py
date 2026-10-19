#!/usr/bin/env python3
"""HAMDMR / DMR-PORTUGAL / BM2681: read-only DB dependency census.
Prints only database metadata, SQLite paths and names of files referencing drivers.
Never prints file contents, configuration values, passwords, SQL data, or proc args.
"""
import os
import re
import sqlite3
import subprocess
import socket
from pathlib import Path
from collections import defaultdict

NAME = socket.gethostname().split('.')[0]
ALLOWED_HOSTS = {'hamdmr', 'bm2681', 'dmr-portugal'}
DB_SOCKETS = ('/run/mysqld/mysqld.sock', '/run/hamdmr-galera/mysqld.sock')
ROOTS = ['/opt', '/var/www/html', '/root/site', '/usr/local/bin', '/usr/local/sbin',
         '/usr/local/libexec', '/srv', '/home', '/etc/systemd/system',
         '/etc/cron.d', '/etc/bm-stats', '/etc/bm-suite', '/etc/mysql',
         '/etc/postgresql', '/etc/redis', '/var/lib']
SKIP_DIRS = {'.git', '__pycache__', 'node_modules', 'vendor', 'vendors', 'venv',
             '.venv', 'site-packages', 'backups', 'backup', 'archive', 'archives',
             'releases', '.cache', 'cache', 'tests', 'test', 'dist', 'build',
             'storage', 'log', 'logs', '.npm', '.composer', 'wheels',
             'mysql', 'hamdmr-galera', 'docker', 'containerd', 'dpkg', 'apt',
             'systemd', 'snapd', 'postgresql'}
# Read potential source/config and unit files; never emit original content.
SUFFIXES = {'.php', '.py', '.sh', '.js', '.ts', '.lua', '.go', '.pl', '.conf',
            '.ini', '.json', '.yaml', '.yml', '.xml', '.service', '.timer',
            '.socket', '.sql', '.inc', '.env', '.rb', '.toml', '.cfg'}
TOKENS = {
  'MariaDB/MySQL': rb'(?i)\b(?:mariadb|mysql|mysqli|pymysql|mysqld|mysql2)\b|(?:pdo_mysql|mysql:host|mysql\+pymysql|DB_HOST|DB_NAME|DB_DATABASE)',
  'SQLite': rb'(?i)\b(?:sqlite3|SQLite|sqlite:|better-sqlite3|rusqlite)\b|\.(?:sqlite3?|db3)\b',
  'PostgreSQL': rb'(?i)\b(?:postgresql|postgres|psycopg2?|pg_connect|pgsql|PDO_PGSQL)\b',
  'Redis': rb'(?i)\b(?:redis-server|redis|predis|ioredis)\b',
  'SQLAlchemy/ORM': rb'(?i)\b(?:sqlalchemy|django\.db|prisma|doctrine|sequelize)\b',
  'DMR Stats': rb'(?i)dmr[_-]stats|dmr[_-]usage|bm[_-]stats|stats[-_]timers',
  'VTS History': rb'(?i)nginx_vts_history|vts[_-]history|vts[_-]sample',
  'osTicket': rb'(?i)osticket|os_ticket|ost-config',
  'WP DMR1': rb'(?i)\bdmr1\b|wp-config',
  'BM App DB': rb'(?i)bm[-_]auth[-_]history|bm[-_]notifications|rf[-_]events|notifications\.sb3|clients\.sb3|usage\.sqlite',
}
RE = {name: re.compile(pattern) for name, pattern in TOKENS.items()}
MAX_FILE_BYTES = 300_000
MAX_LIST = 18


def sql_query(sock, query):
    try:
        x = subprocess.run(['mariadb', '--no-defaults', '--protocol=socket',
                            '--socket='+sock, '--batch', '--skip-column-names',
                            '--connect-timeout=2', '--execute='+query],
                           capture_output=True, text=True, timeout=10, check=False)
        if x.returncode != 0:
            return None
        return x.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None


def classify(path):
    p = Path(path)
    seg = p.parts
    if len(seg) > 2 and seg[:2] == ('/', 'opt'):
        return '/opt/' + seg[2]
    if len(seg) > 3 and seg[:3] == ('/', 'root', 'site'):
        return '/root/site/' + seg[3]
    if len(seg) > 4 and seg[:3] == ('/', 'var', 'www'):
        return '/var/www/' + seg[3] + ('/' + seg[4] if len(seg) > 4 else '')
    if len(seg) > 2 and seg[:2] == ('/', 'etc'):
        return '/etc/' + seg[2]
    if len(seg) > 3 and seg[:3] == ('/', 'usr', 'local'):
        return '/usr/local/' + seg[3]
    return str(p.parent)


def scan():
    items = defaultdict(lambda: {'scanned': 0, 'tags': defaultdict(list), 'sqlite': []})
    sqlite_found = set()
    stats = defaultdict(int)
    seen = set()
    roots = [Path(x) for x in ROOTS]
    site = Path('/root/site')
    if site.is_dir():
        try:
            for project in site.iterdir():
                for name in ('current', 'live', 'production'):
                    node = project/name
                    if node.is_symlink() and node.resolve().is_dir():
                        roots.append(node.resolve())
        except OSError:
            pass
    for base in roots:
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base, followlinks=False):
            dirs[:] = sorted([d for d in dirs if d.lower() not in SKIP_DIRS
                              and not d.startswith('.') and not (root == '/opt' and d in ('aprsc',))])
            for fname in sorted(files):
                path = os.path.join(root, fname)
                try:
                    st = os.stat(path, follow_symlinks=False)
                    if not os.path.isfile(path) or os.path.islink(path):
                        continue
                    ident = (st.st_dev, st.st_ino)
                    if ident in seen:
                        continue
                    seen.add(ident)
                    stats['all_files'] += 1
                    size = st.st_size
                    group = classify(path)
                    lower = fname.lower()
                    suffix = Path(fname).suffix.lower()
                    if suffix in ('.db', '.db3', '.sqlite', '.sqlite3'):
                        with open(path, 'rb') as fd:
                            magic = fd.read(16)
                        if magic == b'SQLite format 3\x00':
                            sqlite_found.add(path)
                            items[group]['sqlite'].append((path, size))
                            stats['sqlite'] += 1
                    if size > MAX_FILE_BYTES:
                        stats['large_skip'] += 1
                        continue
                    if suffix not in SUFFIXES and lower not in ('wp-config.php','config.inc.php', 'settings', 'config', 'database.yml'):
                        continue
                    if (path.startswith('/etc/') and any(x in lower for x in ('private','secret','password','key.pem'))):
                        continue
                    with open(path, 'rb') as f:
                        data = f.read(MAX_FILE_BYTES + 1)
                    if b'\0' in data[:8192]:
                        continue
                    stats['source_files'] += 1
                    groupdata = items[group]
                    groupdata['scanned'] += 1
                    for tag, pat in RE.items():
                        if pat.search(data):
                            groupdata['tags'][tag].append(path)
                except (OSError, PermissionError, ValueError):
                    stats['inaccessible'] += 1
    return items, sorted(sqlite_found), stats


def sqlite_meta(path):
    try:
        from urllib.parse import quote
        uri = 'file:'+quote(path, safe='/')+'?mode=ro&immutable=1'
        con = sqlite3.connect(uri, uri=True, timeout=1)
        try:
            rows = con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
            return ','.join(x[0] for x in rows[:12]) + ('...' if len(rows)>12 else '')
        finally:
            con.close()
    except (sqlite3.Error, OSError):
        return '(estrutura indisponivel sem escrita)'


def sys_units():
    try:
        p = subprocess.run(['systemctl','list-unit-files','--type=service','--type=timer','--no-legend','--no-pager'],
                           text=True,capture_output=True,timeout=12)
        output = []
        for row in p.stdout.splitlines():
            unit = row.split(maxsplit=1)[0] if row.split() else ''
            if re.search(r'(?i)^(?:hamdmr|bm[-@]|dmr[-@]|mumble|mariadb|mysql|postgres|redis|nginx|apache|php|osticket|galera|fail2ban|wp[-@]|stats[-@])',unit):
                output.append(unit)
        return sorted(set(output))
    except (OSError,subprocess.TimeoutExpired):
        return []


def main():
    if NAME not in ALLOWED_HOSTS:
        print('HOST_NOT_IN_PLANNED_THREE='+NAME)
        raise SystemExit(2)
    print('===== DATABASE DEPENDENCY AUDIT r1 =====')
    print('HOST='+NAME)
    print('MODE=READ_ONLY; NO SQL DATA; NO CONFIG VALUES; NO CREDENTIALS')
    for sock in DB_SOCKETS:
        if not os.path.exists(sock):
            continue
        print('\n=== SQL INSTANCE SOCKET='+sock+' ===')
        head = sql_query(sock, 'SELECT @@port,@@version,@@wsrep_on')
        if head is None:
            print('METADATA=NOT_ACCESSIBLE_AS_ROOT')
            continue
        print('SQL_INSTANCE='+head.replace('\t',' | '))
        q=("SELECT t.TABLE_SCHEMA,COALESCE(t.ENGINE,'UNKNOWN'),COUNT(*),"
           "COALESCE(SUM(t.DATA_LENGTH+t.INDEX_LENGTH),0) FROM information_schema.TABLES t "
           "WHERE t.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') "
           "AND t.TABLE_TYPE='BASE TABLE' GROUP BY t.TABLE_SCHEMA,t.ENGINE ORDER BY t.TABLE_SCHEMA,t.ENGINE")
        data=sql_query(sock,q)
        print('SCHEMA | ENGINE | TABLES | BYTES')
        print(data if data else '(none)')
        pkq=("SELECT t.TABLE_SCHEMA,COUNT(*) FROM information_schema.TABLES t "
            "WHERE t.TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') "
            "AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS "
            "(SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c "
            "WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME "
            "AND c.CONSTRAINT_TYPE='PRIMARY KEY') GROUP BY t.TABLE_SCHEMA ORDER BY t.TABLE_SCHEMA")
        no_pk=sql_query(sock,pkq)
        print('SCHEMAS_WITHOUT_PK='+str(no_pk if no_pk else 'NONE'))
    print('\n=== ACTIVE PROJECT UNIT NAMES ===')
    units=sys_units()
    for u in units:
        print(u)
    print('PROJECT_UNITS='+str(len(units)))
    print('\n=== CODE/CONFIG DEPENDENCIES BY PROJECT (FILE NAMES ONLY) ===')
    grouped, databases, stats=scan()
    for group, obj in sorted(grouped.items()):
        tags=obj['tags']
        if not tags and not obj['sqlite']:
            continue
        print('\nPROJECT='+group+' SOURCE_FILES_SCANNED='+str(obj['scanned']))
        for tag in TOKENS:
            paths=tags.get(tag,[])
            if paths:
                print('TAG='+tag+' MATCHED_FILES='+str(len(paths)))
                for path in paths[:MAX_LIST]:
                    print('  '+path)
                if len(paths)>MAX_LIST:
                    print('  ... '+str(len(paths)-MAX_LIST)+' additional files (not printed)')
    print('\n=== SQLITE DATABASE FILES (READ-ONLY INVENTORY) ===')
    for path in databases:
        try:
            size=Path(path).stat().st_size
            tables=sqlite_meta(path)
            print('SQLITE='+path+' BYTES='+str(size)+' TABLES='+tables)
        except OSError:
            print('SQLITE='+path+' METADATA_UNAVAILABLE')
    print('FILES_VISITED='+str(stats['all_files']))
    print('SOURCE_FILES_SCANNED='+str(stats['source_files']))
    print('SQLITE_COUNT='+str(len(databases)))
    print('SKIPPED_LARGE_FILES='+str(stats['large_skip']))
    print('INACCESSIBLE_FILES='+str(stats['inaccessible']))
    print('EXCLUSIONS=dependencies/vendor/archives/backups/tests; scripts containing DB names only in dynamically generated runtime could be missed')
    print('AUDIT_COMPLETE=YES')
    print('MIGRATION_APPLIED=NO')

if __name__=='__main__':
    main()
