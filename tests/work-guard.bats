load work-helpers

setup() {
  setup_work
  G="$WORK_ROOT/bin/work-guard"
  make_project app
  A="$PROJECTS/app"
}

# guard <outil> <tool_input JSON> [cwd] [session] : entrée PreToolUse sur stdin du hook
guard() {
  jq -nc --arg t "$1" --argjson i "$2" --arg c "${3:-$A}" --arg s "${4:-sess-me}" \
    '{session_id: $s, cwd: $c, hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}' \
    | "$G"
}

@test "écriture hors de tout projet : autorisée" {
  run guard Edit '{"file_path":"/elsewhere/x.php"}' /elsewhere
  [ "$status" -eq 0 ]
}

@test "fichier ignoré par git : autorisé même sans ticket" {
  echo 'var/' > "$A/.gitignore"
  run guard Write "{\"file_path\":\"$A/var/cache/x\"}"
  [ "$status" -eq 0 ]
}

@test "outil de lecture : autorisé même sans ticket" {
  run guard Read "{\"file_path\":\"$A/README\"}"
  [ "$status" -eq 0 ]
}

@test "projet libre : écriture bloquée avec la marche à suivre" {
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"aucun ticket démarré"* ]]
  [[ "$output" == *"work start"* ]]

  run guard NotebookEdit "{\"notebook_path\":\"$A/n.ipynb\"}"
  [ "$status" -eq 2 ]
  run guard MultiEdit "{\"file_path\":\"$A/src/x.php\",\"edits\":[]}"
  [ "$status" -eq 2 ]
}

@test "ticket tenu par la session, sur sa branche : écritures autorisées" {
  (cd "$A" && work start GEL-1 >/dev/null)
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 0 ]
  run guard Bash '{"command":"git commit -m x"}'
  [ "$status" -eq 0 ]
}

@test "ticket tenu par la session mais mauvaise branche : bloqué" {
  (cd "$A" && work start GEL-1 >/dev/null)
  git -C "$A" checkout -q develop
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"branche"* ]]
}

@test "ticket tenu par une autre session vivante : lecture seule" {
  live_session s-other
  (cd "$A" && CLAUDE_CODE_SESSION_ID=s-other work start GEL-1 >/dev/null)
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lecture seule"* ]]
  [[ "$output" == *"GEL-1"* ]]
}

@test "ticket tenu par une session terminée : bloqué avec work takeover" {
  dead_session s-old
  (cd "$A" && CLAUDE_CODE_SESSION_ID=s-old work start GEL-1 >/dev/null)
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"work takeover"* ]]
}

@test "Bash : lecture autorisée, écriture bloquée sur un projet libre" {
  run guard Bash '{"command":"git status && cat README"}'
  [ "$status" -eq 0 ]
  run guard Bash '{"command":"rm README"}'
  [ "$status" -eq 2 ]
}

@test "Bash : écriture par chemin absolu depuis un cwd hors projet : bloquée" {
  run guard Bash "{\"command\":\"sed -i s/a/b/ $A/README\"}" /tmp
  [ "$status" -eq 2 ]
}

@test "work lui-même passe toujours" {
  run guard Bash '{"command":"work start GEL-1"}'
  [ "$status" -eq 0 ]
}

@test "WORK_GUARD=off et entrée invalide : autorisé (fail-open)" {
  WORK_GUARD=off run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 0 ]
  run bash -c "echo 'pas du json' | '$G'"
  [ "$status" -eq 0 ]
}

@test "décision en moins de 300 ms" {
  local t0 t1
  t0=$(date +%s%N)
  guard Bash '{"command":"git status && make test"}' >/dev/null 2>&1 || true
  t1=$(date +%s%N)
  [ $(( (t1 - t0) / 1000000 )) -lt 300 ]
}

@test "un blocage est journalisé, une écriture autorisée ne l'est pas" {
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  J="$CONSOLE_STATE/events-$(date -u +%Y-%m-%d).jsonl"

  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [ -f "$J" ]
  tail -n1 "$J" | jq -e '.event == "guard.block" and .project == "app" and .session == "sess-me"
    and .tool == "Edit" and (.summary | test("aucun ticket"))' >/dev/null

  (cd "$A" && work start GEL-1 >/dev/null)
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$J")" -eq 1 ]
}

@test "le journal des blocages ne fait jamais échouer la garde" {
  export CONSOLE_STATE=/proc/impossible/state
  run guard Edit "{\"file_path\":\"$A/src/x.php\"}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"aucun ticket démarré"* ]]
}
