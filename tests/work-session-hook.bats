load work-helpers

setup() {
  setup_work
  H="$WORK_ROOT/bin/work-session-hook"
  make_project app
  A="$PROJECTS/app"
}

# hook_in <cwd> [session] : entrée SessionStart sur stdin du hook
hook_in() {
  jq -nc --arg c "$1" --arg s "${2:-sess-me}" \
    '{session_id: $s, cwd: $c, hook_event_name: "SessionStart", source: "startup"}' | "$H"
}

ctx() { echo "$output" | jq -r '.hookSpecificOutput.additionalContext'; }

@test "silencieux hors projet" {
  run hook_in /tmp
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "projet libre : lecture seule tant que work start n'est pas fait" {
  run hook_in "$A"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  [[ "$(ctx)" == *"app"*"libre"*"work start"* ]]
}

@test "ticket tenu par cette session" {
  (cd "$A" && work start GEL-1 >/dev/null)
  run hook_in "$A" sess-me
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"GEL-1"*"tenu par toi"* ]]
}

@test "ticket tenu par une autre session : lecture seule" {
  live_session s-other
  (cd "$A" && CLAUDE_CODE_SESSION_ID=s-other work start GEL-1 >/dev/null)
  run hook_in "$A" sess-me
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"autre session"*"lecture seule"* ]]
}

@test "PR en attente et dérive hors workflow signalées" {
  echo '{"state":"free","pending_prs":[{"ticket":"GEL-0","branch":"feature/GEL-0","base":"develop","number":3,"url":"https://github.com/o/r/pull/3","parked":false}]}' > "$A/.git/claude-work.json"
  echo x > "$A/new.txt"
  run hook_in "$A"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"PR en attente"*"GEL-0"* ]]
  [[ "$(ctx)" == *"hors workflow"* ]]
}

@test "un sous-dossier du projet est reconnu" {
  mkdir -p "$A/src"
  run hook_in "$A/src"
  [ "$status" -eq 0 ]
  [[ "$(ctx)" == *"app"* ]]
}

@test "entrée invalide : exit 0 sans sortie" {
  run bash -c "echo 'pas du json' | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
