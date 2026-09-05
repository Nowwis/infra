# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
WT_DB_CONTAINER="${WT_DB_CONTAINER:-infra_mariadb_11_3}"
_wt_db_rootpw() {
  local f="${WT_ENV_FILE:-$WT_ROOT/.env}"
  [ -f "$f" ] || die "env file with MYSQL_ROOT_PASSWORD not found: $f"
  awk -F= '/^MYSQL_ROOT_PASSWORD=/{print $2; exit}' "$f"
}
_wt_db_sql() { # runs a SQL string as root
  local sql="$1" pw
  # Ruling E: in dry-run wt_run never executes, so the real root password is
  # not needed — use a placeholder and do NOT read/require the env file.
  if [ "$WT_DRY_RUN" = "1" ]; then pw='***'; else pw="$(_wt_db_rootpw)"; fi
  wt_run docker exec "$WT_DB_CONTAINER" mysql -uroot -p"$pw" -e "$sql"
}
wt_db_create() { # db pass
  local db="$1" pass="$2"
  _wt_db_sql "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4; \
CREATE USER IF NOT EXISTS '$db'@'%' IDENTIFIED BY '$pass'; \
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$db'@'%'; FLUSH PRIVILEGES;"
}
wt_db_drop() { # db
  local db="$1"
  _wt_db_sql "DROP DATABASE IF EXISTS \`$db\`; DROP USER IF EXISTS '$db'@'%'; FLUSH PRIVILEGES;"
}
