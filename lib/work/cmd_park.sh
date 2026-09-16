# shellcheck shell=bash
# work park — met le ticket de côté (commit wip + push), revient sur main. Jamais de stash.

_work_park() {
  local st ticket branch
  st="$(work_state_get)"
  work_require_mine "$st"
  ticket="$(jq -r .ticket <<<"$st")"
  branch="$(jq -r .branch <<<"$st")"

  if ! work_is_clean; then
    git -C "$WP_REPO" add -A && git -C "$WP_REPO" commit -q -m "wip: $ticket parked" \
      || work_die "commit wip impossible sur $branch"
  fi
  git -C "$WP_REPO" push -q -u origin "$branch" || work_die "push de $branch impossible"
  git -C "$WP_REPO" checkout -q "$WP_MAIN" || work_die "retour sur $WP_MAIN impossible"
  work_state_put "$(work_state_release "$st" "" "" true)"
  work_sync_bases
  work_say "✓ $ticket mis de côté sur $branch (poussée) ; retour sur $WP_MAIN à jour. Reprise : work resume $ticket"
}

cmd_park() {
  [ $# -eq 0 ] || work_die "usage : work park"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_park
}
