# shellcheck shell=bash
# work takeover — la session courante reprend le ticket actif (sur demande explicite de Simon).

_work_takeover() {
  local st old me
  st="$(work_state_get)"
  [ "$(jq -r .state <<<"$st")" = active ] || work_die "aucun ticket actif sur $WP_NAME"
  old="$(jq -r .owner_session <<<"$st")"
  me="$(work_session_id)"
  if [ "$old" = "$me" ]; then
    work_say "le ticket $(jq -r .ticket <<<"$st") est déjà tenu par cette session"
    return 0
  fi
  if work_session_alive "$old"; then
    work_warn "l'ancienne session $old est encore active : elle ne pourra plus écrire sur $WP_NAME"
  else
    work_say "ancienne session $old terminée"
  fi
  work_state_put "$(jq --arg me "$me" '.owner_session = $me' <<<"$st")"
  work_say "✓ ticket $(jq -r .ticket <<<"$st") ($(jq -r .branch <<<"$st")) repris par cette session."
}

cmd_takeover() {
  [ $# -eq 0 ] || work_die "usage : work takeover"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_takeover
}
