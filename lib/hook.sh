# shellcheck shell=bash
wt_hook_app_for_cwd() { # cwd apps_conf -> "app\trepo\tbase" or non-zero
  local cwd="$1" conf="$2" app repo type base rest
  [ -f "$conf" ] || return 1
  # longest repo prefix wins
  local best_app="" best_repo="" best_base="" best_len=-1
  while IFS='|' read -r app repo type base rest; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    case "$cwd/" in
      "$repo"/*) if [ "${#repo}" -gt "$best_len" ]; then best_len=${#repo}; best_app="$app"; best_repo="$repo"; best_base="$base"; fi;;
    esac
  done < "$conf"
  [ -n "$best_app" ] || return 1
  printf '%s\t%s\t%s' "$best_app" "$best_repo" "$best_base"
}
wt_hook_is_wip() { # repo base -> 0 if wip
  local repo="$1" base="$2" cur
  [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && return 0
  cur="$(git -C "$repo" branch --show-current 2>/dev/null)"
  [ -n "$cur" ] && [ "$cur" != "$base" ]
}
wt_hook_build_context() { # app branch nchanges envs_tsv -> suggestion text, empty if nothing to say
  local app="$1" branch="$2" n="$3" envs="$4" out=""
  [ -n "$branch" ] && out="wt · ${app} : travail en cours (branche ${branch}, ${n} fichier(s) modifié(s)). Pour isoler un nouveau ticket : demande « nouveau worktree <TICKET> » (→ wt create)."
  if [ -n "$envs" ]; then
    [ -n "$out" ] && out+=$'\n'
    out+="Envs actifs : ${envs}"
  fi
  printf '%s' "$out"
}
