# shellcheck shell=bash
: "${WT_DRY_RUN:=0}"
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '• %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*"; }

# wt_run: execute a command, or print it as a plan line when WT_DRY_RUN=1
wt_run() {
  if [ "$WT_DRY_RUN" = "1" ]; then
    printf '+ %s\n' "$*"
    return 0
  fi
  "$@"
}

confirm() { # confirm "question" ; honors WT_YES=1
  [ "${WT_YES:-0}" = "1" ] && return 0
  local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY] ]]
}
