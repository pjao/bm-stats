#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

SRC_DB=dmr1
DST_DB=dmr1_galera_stage
DST_SOCK=/run/hamdmr-galera/mysqld.sock

[[ $(hostname -s) == dmr-portugal ]] || { echo 'BLOQUEADO=Servidor incorreto'; exit 1; }
SRC_SOCK=$(mariadb --no-defaults -Nse 'SELECT @@socket')
SRC=(mariadb --no-defaults --protocol=socket --socket="$SRC_SOCK")
DST=(mariadb --no-defaults --protocol=socket --socket="$DST_SOCK")
DUMP=(mariadb-dump --no-defaults --protocol=socket --socket="$SRC_SOCK")

[[ $("${SRC[@]}" -Nse 'SELECT @@port') == 3306 ]] || { echo 'BLOQUEADO=Origem inesperada'; exit 1; }
[[ $("${DST[@]}" -Nse 'SELECT @@port') == 3307 ]] || { echo 'BLOQUEADO=Destino inesperado'; exit 1; }
[[ $("${DST[@]}" -Nse "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" | awk '{print $2}') == 3 ]] || { echo 'BLOQUEADO=Cluster incompleto'; exit 1; }
[[ $("${DST[@]}" -Nse "SHOW GLOBAL STATUS LIKE 'wsrep_ready'" | awk '{print $2}') == ON ]] || { echo 'BLOQUEADO=Galera nao preparado'; exit 1; }
[[ $("${DST[@]}" -Nse "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DST_DB'") == 0 ]] || { echo 'BLOQUEADO=Base de ensaio ja existe'; exit 1; }
[[ $("${SRC[@]}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$SRC_DB' AND TABLE_TYPE='BASE TABLE'") == 57 ]] || { echo 'BLOQUEADO=Numero de tabelas de origem alterado'; exit 1; }

WORK=$(mktemp -d /root/galera-wp-stage.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT

echo '=== EXPORTAR ESTRUTURA ==='
"${DUMP[@]}" --no-data --skip-triggers --skip-add-drop-table "$SRC_DB" > "$WORK/schema-original.sql"

python3 - "$WORK/schema-original.sql" "$WORK/schema-galera.sql" <<'PY'
import pathlib, re, sys
source=pathlib.Path(sys.argv[1]).read_text()
count=len(re.findall(r'\bENGINE\s*=\s*MyISAM\b',source,re.I))
if count!=39:
    raise SystemExit(f'BLOQUEADO=Esperadas 39 tabelas MyISAM no DDL, encontradas {count}')
converted=re.sub(r'\bENGINE\s*=\s*MyISAM\b','ENGINE=InnoDB',source,flags=re.I)
pathlib.Path(sys.argv[2]).write_text(converted)
print(f'MYISAM_DDL_CONVERTIDO={count}')
PY

echo '=== CRIAR COPIA ISOLADA NO GALERA ==='
"${DST[@]}" -e "CREATE DATABASE \`$DST_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
"${DST[@]}" --database="$DST_DB" < "$WORK/schema-galera.sql"

echo '=== PROMOVER OS SETE IDENTIFICADORES A CHAVE PRIMARIA ==='
"${DST[@]}" --database="$DST_DB" <<'SQL'
ALTER TABLE dmr_notification_logs ADD PRIMARY KEY (`ID`);
ALTER TABLE dmr_wpdatacharts ADD PRIMARY KEY (`id`);
ALTER TABLE dmr_wpdatatables ADD PRIMARY KEY (`id`);
ALTER TABLE dmr_wpdatatables_cache ADD PRIMARY KEY (`id`);
ALTER TABLE dmr_wpdatatables_columns ADD PRIMARY KEY (`id`);
ALTER TABLE dmr_wpdatatables_rows ADD PRIMARY KEY (`id`);
ALTER TABLE dmr_wpdatatables_templates ADD PRIMARY KEY (`id`);
SQL

echo '=== COPIAR DADOS PARA A BASE DE ENSAIO ==='
"${DUMP[@]}" --single-transaction --quick --skip-triggers --no-create-info \
  --skip-add-locks --skip-disable-keys "$SRC_DB" > "$WORK/data.sql"
"${DST[@]}" --database="$DST_DB" < "$WORK/data.sql"

echo '=== VALIDAR ESTRUTURA DO DESTINO ==='
"${DST[@]}" --table -e "
SELECT COUNT(*) AS tabelas,
       SUM(ENGINE='InnoDB') AS innodb,
       SUM(ENGINE='MyISAM') AS myisam
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='$DST_DB' AND TABLE_TYPE='BASE TABLE';
SELECT COUNT(*) AS tabelas_sem_pk
FROM information_schema.TABLES AS t
WHERE t.TABLE_SCHEMA='$DST_DB' AND t.TABLE_TYPE='BASE TABLE'
 AND NOT EXISTS (
  SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
  WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME
   AND c.CONSTRAINT_TYPE='PRIMARY KEY'
 );
SELECT TABLE_NAME,ENGINE FROM information_schema.TABLES
WHERE TABLE_SCHEMA='$DST_DB' AND ENGINE<>'InnoDB';
"

TOTAL=$("${DST[@]}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DST_DB' AND TABLE_TYPE='BASE TABLE'")
NOTINNO=$("${DST[@]}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DST_DB' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB'")
NOPK=$("${DST[@]}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA='$DST_DB' AND t.TABLE_TYPE='BASE TABLE' AND NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c WHERE c.TABLE_SCHEMA=t.TABLE_SCHEMA AND c.TABLE_NAME=t.TABLE_NAME AND c.CONSTRAINT_TYPE='PRIMARY KEY')")
[[ $TOTAL == 57 && $NOTINNO == 0 && $NOPK == 0 ]] || { echo "STAGING_VALIDATION=FAILED tables=$TOTAL non_innodb=$NOTINNO no_pk=$NOPK"; exit 1; }

for t in dmr_posts dmr_options dmr_users dmr_wpdatatables_templates; do
  old=$("${SRC[@]}" -Nse "SELECT COUNT(*) FROM \`$SRC_DB\`.\`$t\`")
  new=$("${DST[@]}" -Nse "SELECT COUNT(*) FROM \`$DST_DB\`.\`$t\`")
  printf 'TABLE=%s SOURCE_COUNT=%s STAGE_COUNT=%s\n' "$t" "$old" "$new"
done

echo 'WP_GALERA_STAGE=OK'
echo 'SITE_LIVE_DB=UNCHANGED'
echo 'SITE_CONNECTION=UNCHANGED'
echo 'STAGE_DB=dmr1_galera_stage'
echo 'NEXT=Validate WordPress on an isolated staging site before production cutover'
