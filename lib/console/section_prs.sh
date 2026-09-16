# shellcheck shell=bash
# Section prs : état GitHub des PR en attente, par projet et par branche.
# Section lente (réseau) : cadence 5 min, en tâche de fond. GitLab n'est pas interrogé
# (pas de CLI installée) ; les branches mises de côté non plus (elles n'ont pas de PR).

section_prs() {
  local name repo forge state_file branch state out='{}'
  while IFS=$'\t' read -r name repo forge; do
    [ "$forge" = github ] || continue
    state_file="$repo/.git/claude-work.json"
    [ -f "$state_file" ] || continue
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      state="$(cd "$repo" && gh pr view "$branch" --json state --jq .state 2>/dev/null)"
      [ -n "$state" ] || continue
      out="$(jq -c --arg p "$name" --arg b "$branch" --arg s "$state" \
              '.[$p] = ((.[$p] // {}) + {($b): $s})' <<<"$out")"
    done < <(jq -r '.pending_prs[]? | select(.parked != true) | .branch' "$state_file" 2>/dev/null)
  done < <(console_work_projects | jq -r '.[] | [.name, .repo, (.forge // "github")] | @tsv')
  printf '%s' "$out"
}
