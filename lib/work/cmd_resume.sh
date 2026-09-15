# shellcheck shell=bash
# work resume <KEY> — reprend une branche en attente (corrections après relecture, ou ticket mis de côté).

_work_resume() { # key
  local key="$1" st entry branch base
  st="$(work_state_get)"
  [ "$(jq -r .state <<<"$st")" != active ] \
    || work_die "un ticket est déjà actif sur $WP_NAME : $(jq -r .ticket <<<"$st") — work pr ou work park d'abord"
  entry="$(jq -c --arg k "$key" 'first(.pending_prs[] | select(.ticket == $k)) // empty' <<<"$st")"
  [ -n "$entry" ] \
    || work_die "$key n'est pas en attente sur $WP_NAME (en attente : $(jq -r '.pending_prs | map(.ticket) | join(", ")' <<<"$st"))"
  work_is_clean || work_die "arbre de travail non propre sur $WP_NAME ($(work_dirty_count) fichier(s))"
  branch="$(jq -r .branch <<<"$entry")"
  base="$(jq -r .base <<<"$entry")"

  git -C "$WP_REPO" fetch -q origin || work_die "fetch origin impossible ($WP_NAME)"
  if git -C "$WP_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$WP_REPO" checkout -q "$branch" || work_die "checkout $branch impossible"
    if git -C "$WP_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$WP_REPO" pull -q --ff-only origin "$branch" || work_die "$branch a divergé de origin/$branch"
    fi
  elif git -C "$WP_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$WP_REPO" checkout -q -b "$branch" --track "origin/$branch" || work_die "checkout $branch impossible"
  else
    work_die "branche $branch introuvable (ni locale ni sur origin)"
  fi

  work_state_put "$(jq --arg t "$key" --arg b "$branch" --arg base "$base" --arg me "$(work_session_id)" --arg now "$(work_now)" '
      .pending_prs |= map(select(.branch != $b))
      | .state = "active" | .ticket = $t | .branch = $b | .base = $base
      | .owner_session = $me | .started_at = $now' <<<"$st")"
  work_say "✓ $key repris sur $branch."
}

cmd_resume() {
  [ $# -eq 1 ] || work_die "usage : work resume <KEY>"
  work_check_name "$1"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_resume "$1"
}
