# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"

# Conteneur DB cible pour le provisioning local des worktrees. Défaut :
# infra_mysql_8_0 — moteur de la prod (cf. backup/backup.env.*) et de la
# majorité des apps. Surchargé par app via wt_db_resolve_container (source de
# vérité = le DATABASE_URL de l'app), ou par la variable d'env WT_DB_CONTAINER.
WT_DB_CONTAINER="${WT_DB_CONTAINER:-infra_mysql_8_0}"

# Client CLI selon le moteur du conteneur. MariaDB 11 n'expose plus le binaire
# `mysql` (seulement `mariadb`) ; l'image mysql:8.0 n'a que `mysql`. On choisit
# d'après le nom du conteneur pour éviter le « executable file not found »
# (cause du plantage de `wt create` sur infra_mariadb_11_3).
_wt_db_client() {
  case "$WT_DB_CONTAINER" in
    *mariadb*) printf 'mariadb' ;;
    *)         printf 'mysql' ;;
  esac
}

# Résout le conteneur DB depuis le DATABASE_URL de l'app : le host de l'URL EST
# le conteneur auquel l'app se connecte (infra_mysql_8_0 / infra_mariadb_11_3),
# donc la base doit y être créée pour que wt et l'app soient toujours d'accord.
# Sans correspondance (fichier absent, pas de DATABASE_URL), on garde la valeur
# courante (défaut, ou WT_DB_CONTAINER hérité de l'environnement).
wt_db_resolve_container() { # env_local_file
  local f="${1:-}" host
  [ -n "$f" ] && [ -f "$f" ] || return 0
  # DATABASE_URL="scheme://user:pass@HOST[:port]/db?…"  → extrait HOST.
  # `.*@` glouton : on prend le dernier « @ » (tolère un « @ » dans le mot de passe).
  host="$(sed -nE 's/^[[:space:]]*DATABASE_URL=.*@([^:/?"]+).*/\1/p' "$f" | head -n1)"
  [ -n "$host" ] && WT_DB_CONTAINER="$host"
  return 0
}

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
  wt_run docker exec "$WT_DB_CONTAINER" "$(_wt_db_client)" -uroot -p"$pw" -e "$sql"
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
