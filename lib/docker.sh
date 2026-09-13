# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
# Delai max d'attente des healthchecks, en secondes (spec : 180 s).
: "${WT_UP_TIMEOUT:=180}"
wt_docker_up() { # path compose project
  local p="$1" compose="$2" project="$3"
  { [ -d "$p" ] || [ "$WT_DRY_RUN" = 1 ]; } || die "no worktree: $p"
  if ( [ -d "$p" ] && cd "$p"; wt_run docker compose -p "$project" -f "$compose" \
         up -d --build --wait --wait-timeout "$WT_UP_TIMEOUT" ); then
    return 0
  fi
  # --wait a rendu la main en erreur : un service n'est jamais devenu healthy.
  # Sans les logs, le message de docker ne dit pas lequel ni pourquoi.
  warn "un service n'est pas devenu sain en ${WT_UP_TIMEOUT}s — etat et logs :"
  ( [ -d "$p" ] && cd "$p"
    docker compose -p "$project" -f "$compose" ps 2>&1 || true
    docker compose -p "$project" -f "$compose" logs --tail=40 2>&1 || true ) >&2
  return 1
}
wt_docker_down() { # path compose project
  local p="$1"
  ( [ -d "$p" ] && cd "$p"; wt_run docker compose -p "$3" -f "$2" down -v )
}
wt_docker_status() { # project -> count of running containers
  docker ps --filter "label=com.docker.compose.project=$1" -q 2>/dev/null | wc -l
}
