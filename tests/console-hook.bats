load helpers

setup() {
  setup_infra
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  export WORK_CONF="$BATS_TEST_TMPDIR/projects.conf"
  REPO="$BATS_TEST_TMPDIR/Project/app"; mkdir -p "$REPO/src"
  printf 'app|%s|main|develop|github\n' "$REPO" > "$WORK_CONF"
  H="$INFRA_ROOT/bin/console-hook"
  JOURNAL="$CONSOLE_STATE/events-$(date -u +%Y-%m-%d).jsonl"
}

# hook <json> : envoie un payload au hook
hook() { printf '%s' "$1" | "$H"; }

# ev <event> <tool> <tool_input JSON> [extra JSON]
ev() {
  local extra='{}'
  [ $# -ge 4 ] && extra="$4"
  jq -nc --arg e "$1" --arg t "$2" --argjson i "$3" --argjson x "$extra" --arg c "$REPO" \
    '{session_id: "sess-1", cwd: $c, hook_event_name: $e, tool_name: $t, tool_input: $i,
      tool_use_id: "toolu_abc"} + $x'
}

last() { tail -n1 "$JOURNAL"; }

@test "PreToolUse Bash : une ligne avec outil, commande, projet et identifiant d'appel" {
  run hook "$(ev PreToolUse Bash '{"command":"git status && make test"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$JOURNAL")" -eq 1 ]
  last | jq -e '.event == "PreToolUse" and .tool == "Bash" and .session == "sess-1"
    and .project == "app" and .tool_use_id == "toolu_abc"
    and .summary == "git status && make test"
    and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' >/dev/null
}

@test "PostToolUse : résultat ok ou erreur" {
  hook "$(ev PostToolUse Bash '{"command":"make test"}' '{"tool_response":{"is_error":false}}')"
  last | jq -e '.event == "PostToolUse" and .result == "ok"' >/dev/null

  hook "$(ev PostToolUse Bash '{"command":"make test"}' '{"tool_response":{"is_error":true}}')"
  last | jq -e '.result == "error"' >/dev/null
}

@test "Edit et Write : le résumé est le chemin du fichier" {
  hook "$(ev PreToolUse Edit "{\"file_path\":\"$REPO/src/App.php\"}")"
  last | jq -e --arg p "$REPO/src/App.php" '.tool == "Edit" and .summary == $p' >/dev/null
}

@test "le texte des prompts n'est jamais enregistré" {
  run hook "$(jq -nc --arg c "$REPO" '{session_id:"sess-1", cwd:$c, hook_event_name:"UserPromptSubmit",
    prompt:"mot de passe secret à ne jamais journaliser"}')"
  [ "$status" -eq 0 ]
  last | jq -e '.event == "UserPromptSubmit" and .summary == ""' >/dev/null
  run grep -c 'jamais journaliser' "$JOURNAL"
  [ "$output" = 0 ]
}

@test "Notification : le message est repris" {
  hook "$(jq -nc --arg c "$REPO" '{session_id:"sess-1", cwd:$c, hook_event_name:"Notification",
    message:"Claude needs your permission to use Bash"}')"
  last | jq -e '.event == "Notification" and (.summary | test("permission"))' >/dev/null
}

@test "événements de cycle de vie enregistrés" {
  local e
  for e in SessionStart Stop SubagentStop SessionEnd; do
    hook "$(jq -nc --arg c "$REPO" --arg e "$e" '{session_id:"sess-1", cwd:$c, hook_event_name:$e}')"
    last | jq -e --arg e "$e" '.event == $e' >/dev/null
  done
  [ "$(wc -l < "$JOURNAL")" -eq 4 ]
}

@test "secrets masqués : mot de passe, token, Bearer, identifiants d'URL, chaîne longue" {
  hook "$(ev PreToolUse Bash '{"command":"curl -H \"Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345\" https://user:s3cret@example.com/api --token=azerty123456 PASSWORD=hunter2"}')"
  local l; l="$(last)"
  run grep -cE 'abcdefghijklmnopqrstuvwxyz012345|s3cret|azerty123456|hunter2' <<<"$l"
  [ "$output" = 0 ]
  jq -e '.summary | test("Bearer \\*\\*\\*") and test("://\\*\\*\\*@")' <<<"$l" >/dev/null
}

@test "résumé tronqué à 300 caractères" {
  hook "$(ev PreToolUse Bash "{\"command\":\"echo $(head -c 400 < /dev/zero | tr '\0' 'x')\"}")"
  last | jq -e '(.summary | length) <= 300' >/dev/null
}

@test "hors projet géré : ligne écrite sans projet" {
  hook "$(jq -nc '{session_id:"sess-1", cwd:"/tmp", hook_event_name:"PreToolUse", tool_name:"Bash",
    tool_input:{command:"ls"}}')"
  last | jq -e '.project == null and .cwd == "/tmp"' >/dev/null
}

@test "entrée invalide : exit 0, rien écrit, rien sur stdout" {
  run bash -c "echo 'pas du json' | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$JOURNAL" ]
}

@test "moins de 25 ms par appel" {
  # Plancher mesuré sur l'hôte : ~4 ms pour un jq seul, ~5 ms pour un bash. Le budget tient
  # compte de ce plancher ; il reste sous le coût de la garde (~41 ms), qui passe avant.
  local p t0 t1 i
  p="$(ev PreToolUse Bash '{"command":"git status"}')"
  t0=$(date +%s%N)
  for i in 1 2 3 4 5; do hook "$p"; done
  t1=$(date +%s%N)
  [ $(( (t1 - t0) / 5000000 )) -lt 25 ]
}
