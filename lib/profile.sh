# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"

declare -gA WT_APP_REPO WT_APP_TYPE WT_APP_BASE WT_APP_COMPOSE WT_APP_INSTALL
wt_profile_load() {
  local f="${1:-$WT_ROOT/etc/wt/apps.conf}" app repo type base compose install
  [ -f "$f" ] || die "apps.conf not found: $f"
  while IFS='|' read -r app repo type base compose install; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    WT_APP_REPO[$app]="$repo"; WT_APP_TYPE[$app]="$type"
    WT_APP_BASE[$app]="$base"; WT_APP_COMPOSE[$app]="$compose"
    WT_APP_INSTALL[$app]="$install"
  done < "$f"
}
wt_profile_get() {
  local app="$1" field="$2"
  case "$field" in
    repo) printf '%s' "${WT_APP_REPO[$app]:-}";;
    type) printf '%s' "${WT_APP_TYPE[$app]:-}";;
    base) printf '%s' "${WT_APP_BASE[$app]:-}";;
    compose) printf '%s' "${WT_APP_COMPOSE[$app]:-}";;
    install) printf '%s' "${WT_APP_INSTALL[$app]:-}";;
    *) die "unknown field: $field";;
  esac
}
wt_profile_require() {
  local app="$1"
  [ -n "${WT_APP_REPO[$app]:-}" ] || die "unknown app: $app"
  [ "${WT_APP_TYPE[$app]}" = "symfony" ] || die "app '$app' not supported in v1 (type=${WT_APP_TYPE[$app]})"
}
