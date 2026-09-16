# shellcheck shell=bash
# work status [--all] [--json] — état d'un projet (ou de tous) et dérives.

# Objet JSON d'état du projet courant (WP_*).
work_status_json() {
  local st cur dirty untracked me owner alive=false
  st="$(work_state_get)"
  cur="$(work_current_branch)"
  # `dirty` ne compte que les fichiers SUIVIS : un fichier jamais ajouté n'empêche ni un pull
  # ni un changement de branche, ce n'est donc pas une dérive du workflow.
  dirty="$(work_tracked_count)"
  untracked="$(( $(work_dirty_count) - dirty ))"
  me="$(work_session_id)"
  owner="$(jq -r '.owner_session // empty' <<<"$st")"
  [ -n "$owner" ] && work_session_alive "$owner" && alive=true
  jq -n --argjson st "$st" --arg name "$WP_NAME" --arg repo "$WP_REPO" --arg main "$WP_MAIN" \
        --arg cur "$cur" --argjson dirty "${dirty:-0}" --argjson untracked "${untracked:-0}" \
        --arg me "$me" --argjson alive "$alive" '
    ($st.state // "free") as $state
    | {name: $name, repo: $repo, state: $state,
       ticket: ($st.ticket // null), branch: ($st.branch // null),
       owner: ($st.owner_session // null), owner_alive: $alive,
       is_me: (($st.owner_session // "") == $me),
       current_branch: $cur, dirty: $dirty, untracked: $untracked,
       pending_prs: ($st.pending_prs // []),
       drift: [
         (if $state == "free" and ($dirty > 0 or $cur != $main) then "hors-workflow" else empty end),
         (if $state == "active" and ($alive | not) then "verrou-orphelin" else empty end)
       ]}'
}

# Objet JSON → texte lisible.
work_status_text() {
  jq -r '
    "\(.name) : "
    + (if .state == "active" then
         "ticket \(.ticket) sur \(.branch) — "
         + (if .is_me then "tenu par toi"
            elif .owner_alive then "tenu par la session \(.owner[0:8])"
            else "verrou orphelin (session \(.owner[0:8]) terminée)" end)
       else "libre" end)
    + (if (.pending_prs | length) > 0 then
         "\n  PR en attente : "
         + (.pending_prs | map(.ticket + (if .parked then " (mis de côté)" elif .url then " " + .url else "" end)) | join(", "))
       else "" end)
    + (if (.drift | index("hors-workflow")) != null then
         "\n  ⚠ hors workflow : branche \(.current_branch), \(.dirty) fichier(s) modifié(s)"
       else "" end)'
}

cmd_status() {
  local all=0 json=0 a name repo rest out="[]" o
  for a in "$@"; do
    case "$a" in
      --all) all=1 ;;
      --json) json=1 ;;
      *) work_die "option inconnue : $a" ;;
    esac
  done

  if [ "$all" = 0 ]; then
    work_project_for_path "$PWD" || work_die "hors projet : $PWD n'appartient à aucun projet de $WORK_CONF"
    if [ "$json" = 1 ]; then work_status_json; else work_status_json | work_status_text; fi
    return
  fi

  while IFS='|' read -r -u 3 name repo rest; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [ -e "$repo/.git" ] || continue
    work_project_for_path "$repo" || continue
    out="$(jq -c --argjson o "$(work_status_json)" '. + [$o]' <<<"$out")"
  done 3< "$WORK_CONF"

  if [ "$json" = 1 ]; then
    printf '%s\n' "$out"
  else
    while IFS= read -r o; do work_status_text <<<"$o"; done < <(jq -c '.[]' <<<"$out")
  fi
}
