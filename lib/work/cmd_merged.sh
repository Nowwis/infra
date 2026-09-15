# shellcheck shell=bash
# work merged [KEY] [--confirmed] — nettoie une PR mergée (étape facultative du workflow).
# Ne change jamais la branche checkoutée.

_work_merged() { # key confirmed
  local key="$1" confirmed="$2" st n entry branch pending
  st="$(work_state_get)"
  n="$(jq '.pending_prs | length' <<<"$st")"
  pending="$(jq -r '.pending_prs | map(.ticket) | join(", ")' <<<"$st")"
  [ "$n" -gt 0 ] || work_die "aucune PR en attente sur $WP_NAME"

  if [ -n "$key" ]; then
    entry="$(jq -c --arg k "$key" 'first(.pending_prs[] | select(.ticket == $k)) // empty' <<<"$st")"
    [ -n "$entry" ] || work_die "$key n'est pas en attente sur $WP_NAME (en attente : $pending)"
  elif [ "$n" -eq 1 ]; then
    entry="$(jq -c '.pending_prs[0]' <<<"$st")"
  else
    work_die "plusieurs PR en attente, précise le ticket : $pending"
  fi
  branch="$(jq -r .branch <<<"$entry")"
  key="$(jq -r .ticket <<<"$entry")"

  if [ "$WP_FORGE" = github ]; then
    [ "$(work_pr_state "$branch")" = MERGED ] \
      || work_die "la PR de $branch n'est pas mergée sur GitHub : rien n'est supprimé"
  else
    [ "$confirmed" = 1 ] \
      || work_die "GitLab : merge non vérifiable automatiquement ; relance avec --confirmed une fois la MR mergée"
  fi
  [ "$(work_current_branch)" != "$branch" ] || work_die "$branch est la branche courante : repasse sur $WP_MAIN d'abord"

  work_sync_bases
  if git -C "$WP_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    # -D : un merge squash est invisible pour -d ; sûr car le merge vient d'être vérifié.
    git -C "$WP_REPO" branch -q -D "$branch" || work_die "suppression de $branch impossible"
  fi
  work_state_put "$(jq --arg b "$branch" '.pending_prs |= map(select(.branch != $b))' <<<"$st")"
  work_say "✓ $key mergée : main et develop à jour, branche locale $branch supprimée."
}

cmd_merged() {
  local key="" confirmed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirmed) confirmed=1 ;;
      -*) work_die "option inconnue : $1" ;;
      *) if [ -z "$key" ]; then key="$1"; else work_die "argument en trop : $1"; fi ;;
    esac
    shift
  done
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_merged "$key" "$confirmed"
}
