# shellcheck shell=bash
# work pr [--title T --body-file F] — pousse la branche, ouvre la PR, revient sur main.

# URL web de création de MR GitLab, depuis l'URL brute d'origin (insteadOf non appliqué).
work_gitlab_mr_url() { # branch base
  local url host path
  url="$(git -C "$WP_REPO" config --get remote.origin.url)"
  case "$url" in
    git@*:*) host="${url#git@}"; host="${host%%:*}"; path="${url#*:}" ;;
    https://*|http://*) url="${url#*://}"; url="${url#*@}"; host="${url%%/*}"; path="${url#*/}" ;;
    *) return 1 ;;
  esac
  printf 'https://%s/%s/-/merge_requests/new?merge_request[source_branch]=%s&merge_request[target_branch]=%s' \
    "$host" "${path%.git}" "$1" "$2"
}

_work_pr() { # title body_file
  local title="$1" body="$2" st ticket branch base pr_state="" number="" url="" info mr
  st="$(work_state_get)"
  work_require_mine "$st"
  work_is_clean || work_die "arbre de travail non propre ($(work_dirty_count) fichier(s)) : commite avant d'ouvrir la PR"
  ticket="$(jq -r .ticket <<<"$st")"
  branch="$(jq -r .branch <<<"$st")"
  base="$(jq -r .base <<<"$st")"

  if [ "$WP_FORGE" = github ]; then
    pr_state="$(work_pr_state "$branch")"
    if [ "$pr_state" != OPEN ] && { [ -z "$title" ] || [ -z "$body" ] || [ ! -f "$body" ]; }; then
      work_die "aucune PR ouverte pour $branch : --title et --body-file (fichier existant) sont requis"
    fi
  fi

  git -C "$WP_REPO" push -q -u origin "$branch" || work_die "push de $branch impossible"

  if [ "$WP_FORGE" = github ]; then
    if [ "$pr_state" != OPEN ]; then
      ( cd "$WP_REPO" && gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body" >/dev/null ) \
        || work_die "création de la PR impossible (branche déjà poussée : relancer work pr)"
    fi
    info="$(cd "$WP_REPO" && gh pr view "$branch" --json number,url --jq '[.number,.url]|@tsv')" \
      || work_die "PR introuvable pour $branch après création"
    number="${info%%$'\t'*}"
    url="${info#*$'\t'}"
    work_say "✓ PR #$number : $url"
  elif mr="$(work_gitlab_mr_url "$branch" "$base")"; then
    work_say "→ ouvre la MR : $mr"
  else
    work_say "→ ouvre la MR de $branch vers $base sur GitLab"
  fi

  git -C "$WP_REPO" checkout -q "$WP_MAIN" || work_die "retour sur $WP_MAIN impossible"
  work_state_put "$(work_state_release "$st" "$number" "$url" false)"
  work_sync_bases
  work_say "✓ retour sur $WP_MAIN à jour ; $ticket en attente de merge."
}

cmd_pr() {
  local title="" body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="${2:-}"; shift ;;
      --body-file) body="${2:-}"; shift ;;
      *) work_die "option inconnue : $1" ;;
    esac
    shift
  done
  [ -z "$body" ] || body="$(readlink -f -- "$body")"
  work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
  work_locked _work_pr "$title" "$body"
}
