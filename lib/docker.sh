# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
wt_docker_up() { # path compose project
  local p="$1"
  { [ -d "$p" ] || [ "$WT_DRY_RUN" = 1 ]; } || die "no worktree: $p"
  ( [ -d "$p" ] && cd "$p"; wt_run docker compose -p "$3" -f "$2" up -d --build )
}
wt_docker_down() { # path compose project
  local p="$1"
  ( [ -d "$p" ] && cd "$p"; wt_run docker compose -p "$3" -f "$2" down -v )
}
wt_docker_status() { # project -> count of running containers
  docker ps --filter "label=com.docker.compose.project=$1" -q 2>/dev/null | wc -l
}
