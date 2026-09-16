# shellcheck shell=bash
# work start <KEY> [--hotfix] [--slug S] — démarre un ticket depuis main/develop à jour.

# Retire de pending_prs les PR GitHub mergées (hors mises de côté) et supprime leur branche locale.
# Entrée : état JSON ; sortie : état JSON nettoyé ; rapport sur stderr.
work_janitor() {
  local st="$1" entry br keep="[]"
  if [ "$WP_FORGE" != github ]; then printf '%s' "$st"; return; fi
  while IFS= read -r entry; do
    br="$(jq -r .branch <<<"$entry")"
    if [ "$(jq -r .parked <<<"$entry")" != true ] && [ "$(work_pr_state "$br")" = MERGED ]; then
      git -C "$WP_REPO" branch -q -D "$br" 2>/dev/null
      work_warn "ménage : $(jq -r .ticket <<<"$entry") mergée, branche locale $br supprimée"
      continue
    fi
    keep="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$keep")"
  done < <(jq -c '.pending_prs[]' <<<"$st")
  jq -c --argjson k "$keep" '.pending_prs = $k' <<<"$st"
}

_work_start() { # key slug hotfix
  local key="$1" slug="$2" hotfix="$3" st base branch pending
  st="$(work_state_get)"
  if [ "$(jq -r .state <<<"$st")" = active ]; then
    work_die "un ticket est déjà actif sur $WP_NAME : $(jq -r .ticket <<<"$st") ($(jq -r .branch <<<"$st")). Termine-le (work pr ou work park) avant d'en démarrer un autre."
  fi
  work_is_clean || work_die "arbre de travail non propre sur $WP_NAME ($(work_dirty_count) fichier(s)) : commit, ou demande à Simon quoi en faire."

  if [ "$hotfix" = 1 ]; then
    base="$WP_MAIN"; branch="hotfix/$key"
  else
    base="${WP_DEVELOP:-$WP_MAIN}"; branch="feature/$key"
  fi
  [ -n "$slug" ] && branch="$branch-$slug"

  git -C "$WP_REPO" fetch -q origin || work_die "fetch origin impossible ($WP_NAME)"
  if git -C "$WP_REPO" show-ref --verify --quiet "refs/heads/$branch" \
     || git -C "$WP_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    work_die "la branche $branch existe déjà (locale ou origin) : work resume $key, ou choisis un autre slug."
  fi

  git -C "$WP_REPO" checkout -q "$WP_MAIN" || work_die "checkout $WP_MAIN impossible sur $WP_NAME"
  st="$(work_janitor "$st")"
  work_state_put "$st"
  work_sync_bases
  git -C "$WP_REPO" checkout -q -b "$branch" "$base" || work_die "création de $branch impossible"

  st="$(jq --arg t "$key" --arg b "$branch" --arg base "$base" --arg me "$(work_session_id)" --arg now "$(work_now)" \
    '.state = "active" | .ticket = $t | .branch = $b | .base = $base | .owner_session = $me | .started_at = $now' <<<"$st")"
  work_state_put "$st"
  work_say "✓ $WP_NAME : $branch créée depuis $base à jour — prêt à coder."

  pending="$(jq -r '.pending_prs | map(.ticket) | join(", ")' <<<"$st")"
  [ -z "$pending" ] || work_warn "PR en attente sur ce projet : $pending — ce ticket ne contiendra pas leur code tant qu'elles ne sont pas mergées."
}

cmd_start() {
  local key="" slug="" hotfix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hotfix) hotfix=1 ;;
      --slug) slug="${2:-}"; shift ;;
      -*) work_die "option inconnue : $1" ;;
      *) if [ -z "$key" ]; then key="$1"; else work_die "argument en trop : $1"; fi ;;
    esac
    shift
  done
  [ -n "$key" ] || work_die "usage : work start <KEY> [--hotfix] [--slug S]"
  work_check_name "$key"
  [ -z "$slug" ] || work_check_name "$slug"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_start "$key" "$slug" "$hotfix"
}
