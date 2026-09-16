# shellcheck shell=bash
# Section projects : état `work` de chaque projet (ticket, branche, propriétaire, dérives),
# enrichi de l'état GitHub des PR en attente, lu dans la section prs déjà collectée.

section_projects() {
  local raw prs
  raw="$("$CONSOLE_ROOT/bin/work" status --all --json 2>/dev/null)"
  jq -e . >/dev/null 2>&1 <<<"$raw" || raw='[]'
  prs="$(jq -c '.data // {}' "$CONSOLE_SECTIONS_DIR/prs.json" 2>/dev/null)"
  [ -n "$prs" ] || prs='{}'

  jq -c -n --argjson projects "$raw" --argjson prs "$prs" '
    $projects | map(. as $p
      | .pending_prs |= map(. + {gh_state: ((($prs[$p.name]) // {})[.branch] // null)}))'
}
