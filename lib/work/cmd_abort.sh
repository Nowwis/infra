# shellcheck shell=bash
# work abort [--force] — abandonne le ticket en cours : retour sur main, suppression de la
# branche LOCALE (jamais la distante), projet libéré. Les PR en attente sont conservées.
# Sans --force, refuse dès qu'il y a quelque chose à perdre et renvoie vers `work park`.

_work_abort() { # force(0|1)
  local force="$1" st ticket branch base owner cur commits=0 changes=0 lost="" remote=""
  st="$(work_state_get)"
  [ "$(jq -r .state <<<"$st")" = active ] || work_die "aucun ticket actif sur $WP_NAME"
  owner="$(jq -r .owner_session <<<"$st")"
  [ "$owner" = "$(work_session_id)" ] \
    || work_die "le ticket $(jq -r .ticket <<<"$st") est tenu par une autre session ($owner) : work takeover si elle est terminée"

  ticket="$(jq -r .ticket <<<"$st")"
  branch="$(jq -r .branch <<<"$st")"
  base="$(jq -r .base <<<"$st")"
  cur="$(work_current_branch)"

  if git -C "$WP_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    commits="$(git -C "$WP_REPO" rev-list --count "$base..$branch" 2>/dev/null || echo 0)"
    git -C "$WP_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch" && remote=1
  fi
  # Les modifications non commitées ne concernent le ticket que si sa branche est checkoutée.
  [ "$cur" = "$branch" ] && changes="$(work_tracked_count)"

  [ "$commits" -gt 0 ] && lost="$commits commit(s)"
  [ "$changes" -gt 0 ] && lost="${lost:+$lost et }$changes fichier(s) suivi(s) modifié(s)"

  if [ -n "$lost" ] && [ "$force" != 1 ]; then
    work_die "abandon refusé sur $WP_NAME : $lost seraient perdus. « work park » conserve tout (commit wip + push), ou relance avec --force."
  fi

  if [ "$cur" = "$branch" ]; then
    # --force : le checkout doit écraser les modifications que l'on vient d'annoncer perdues.
    git -C "$WP_REPO" checkout --force -q "$WP_MAIN" || work_die "retour sur $WP_MAIN impossible"
  fi
  if git -C "$WP_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$WP_REPO" branch -q -D "$branch" || work_die "suppression de $branch impossible"
  fi

  work_state_put "$(jq 'del(.ticket, .branch, .base, .owner_session, .started_at) | .state = "free"' <<<"$st")"
  work_say "✓ $WP_NAME : ticket $ticket abandonné, branche locale $branch supprimée${lost:+ ($lost perdus)}."
  [ -n "$remote" ] && work_say "  la branche distante origin/$branch est conservée : à supprimer à la main si besoin."
  return 0
}

cmd_abort() {
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      *) work_die "option inconnue : $1" ;;
    esac
    shift
  done
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_abort "$force"
}
