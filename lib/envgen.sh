# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"

wt_gen_docker_env() { # src dst project domain
  local src="$1" dst="$2" project="$3" domain="$4"
  [ -f "$src" ] || die "missing .docker/.env: $src"
  sed -E \
    -e "s#^COMPOSE_PROJECT_NAME=.*#COMPOSE_PROJECT_NAME=${project}#" \
    -e "s#^COMPOSE_PROJECT_DOMAIN=.*#COMPOSE_PROJECT_DOMAIN=${domain}#" \
    -e "s#^APP_FOLDER=.*#APP_FOLDER=../#" \
    "$src" > "$dst"
}

wt_patch_env_local() { # src dst domain db pass
  local src="$1" dst="$2" domain="$3" db="$4" pass="$5"
  [ -f "$src" ] || die "missing .env.local: $src"
  # rewrite APP_URL; rewrite the db credentials + name in DATABASE_URL, keep host + query
  sed -E \
    -e "s#^APP_URL=.*#APP_URL=https://${domain}#" \
    -e "s#(mysql://)[^:]+:[^@]+@([^/]+)/[^?\"']+#\1${db}:${pass}@\2/${db}#" \
    "$src" > "$dst"
}
