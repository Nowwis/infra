# shellcheck shell=bash
# work sync [--tidy] — met main et develop à jour (avance rapide) sans démarrer de ticket.
# --tidy : si la branche courante n'est pas une base et que sa PR est mergée, revient sur main
# et supprime la branche locale. Ne touche jamais à une branche qui porte un ticket actif.

_work_sync_is_base() { [ "$1" = "$WP_MAIN" ] || { [ -n "$WP_DEVELOP" ] && [ "$1" = "$WP_DEVELOP" ]; }; }

_work_sync_tidy() { # branche courante → affiche la nouvelle branche courante
  local cur="$1" st pr
  st="$(work_state_get)"
  if [ "$(jq -r .state <<<"$st")" = active ]; then
    work_warn "$WP_NAME : ticket $(jq -r .ticket <<<"$st") en cours — branche $cur laissée en place"
  elif _work_sync_is_base "$cur"; then
    :
  elif work_has_tracked_changes; then
    work_warn "$WP_NAME : fichiers suivis modifiés — branche $cur laissée en place"
  elif [ "$WP_FORGE" != github ]; then
    work_warn "$WP_NAME : forge sans vérification automatique — branche $cur laissée en place"
  else
    git -C "$WP_REPO" fetch -q origin
    pr="$(work_pr_state "$cur")"
    if [ "$pr" = MERGED ]; then
      if git -C "$WP_REPO" checkout -q "$WP_MAIN" && git -C "$WP_REPO" branch -q -D "$cur"; then
        work_say "✓ $WP_NAME : $cur (PR mergée) supprimée, retour sur $WP_MAIN"
        cur="$WP_MAIN"
      else
        work_warn "$WP_NAME : retrait de $cur impossible"
      fi
    else
      work_warn "$WP_NAME : branche $cur conservée (PR ${pr:-absente})"
    fi
  fi
  printf '%s' "$cur"
}

_work_sync() { # tidy(0|1)
  local tidy="$1" cur b after count i=0
  local -a names=() befores=()
  cur="$(work_current_branch)"

  [ "$tidy" = 1 ] && cur="$(_work_sync_tidy "$cur")"

  if _work_sync_is_base "$cur" && work_has_tracked_changes; then
    work_die "fichiers suivis modifiés sur $WP_NAME ($(work_tracked_count)) : rien n'a été synchronisé"
  fi

  for b in "$WP_MAIN" "$WP_DEVELOP"; do
    [ -n "$b" ] || continue
    names+=("$b")
    befores+=("$(git -C "$WP_REPO" rev-parse "$b" 2>/dev/null || echo '')")
  done

  work_sync_bases

  for b in "${names[@]}"; do
    after="$(git -C "$WP_REPO" rev-parse "$b" 2>/dev/null || echo '')"
    if [ -z "${befores[$i]}" ]; then
      work_say "  $b : créée depuis origin/$b"
    elif [ "${befores[$i]}" = "$after" ]; then
      work_say "  $b : déjà à jour"
    else
      count="$(git -C "$WP_REPO" rev-list --count "${befores[$i]}..$after" 2>/dev/null || echo '?')"
      work_say "  $b : +$count commit(s)"
    fi
    i=$((i + 1))
  done
  work_say "✓ $WP_NAME synchronisé (branche courante : $cur)"
}

cmd_sync() {
  local tidy=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tidy) tidy=1 ;;
      *) work_die "option inconnue : $1" ;;
    esac
    shift
  done
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_sync "$tidy"
}
