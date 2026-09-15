# shellcheck shell=bash
# work adopt <KEY> — enregistre la branche courante comme ticket actif, sans toucher à git (migration).

_work_adopt() { # key
  local key="$1" st cur base
  st="$(work_state_get)"
  [ "$(jq -r .state <<<"$st")" != active ] \
    || work_die "un ticket est déjà actif sur $WP_NAME : $(jq -r .ticket <<<"$st")"
  cur="$(work_current_branch)"
  [ -n "$cur" ] || work_die "HEAD détachée : checkout une branche avant work adopt"
  if [ "$cur" = "$WP_MAIN" ] || { [ -n "$WP_DEVELOP" ] && [ "$cur" = "$WP_DEVELOP" ]; }; then
    work_die "la branche courante est $cur (main ou develop) : rien à adopter, utilise work start"
  fi
  case "$cur" in
    hotfix/*) base="$WP_MAIN" ;;
    *) base="${WP_DEVELOP:-$WP_MAIN}" ;;
  esac

  work_state_put "$(jq --arg t "$key" --arg b "$cur" --arg base "$base" --arg me "$(work_session_id)" --arg now "$(work_now)" '
      .state = "active" | .ticket = $t | .branch = $b | .base = $base
      | .owner_session = $me | .started_at = $now' <<<"$st")"
  work_say "✓ $cur adoptée comme ticket $key (base $base)."
}

cmd_adopt() {
  [ $# -eq 1 ] || work_die "usage : work adopt <KEY>"
  work_check_name "$1"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_adopt "$1"
}
