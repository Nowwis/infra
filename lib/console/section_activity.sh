# shellcheck shell=bash
# Section activity : les 200 derniers événements du journal (aujourd'hui + la veille),
# du plus récent au plus ancien. Purge au passage les journaux de plus de 7 jours.

section_activity() {
  local events
  console_journal_purge
  events="$(console_journal_events)"
  [ -n "$events" ] || events='[]'
  jq -c -n --argjson events "$events" '$events | reverse | .[0:200]'
}
