load helpers

setup() {
  setup_infra
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  export CONSOLE_SESSIONS_DIR="$BATS_TEST_TMPDIR/sessions"; mkdir -p "$CONSOLE_SESSIONS_DIR"
  export WORK_CONF="$BATS_TEST_TMPDIR/projects.conf"
  REPO="$BATS_TEST_TMPDIR/Project/app"; mkdir -p "$REPO/.git"
  printf 'app|%s|main|develop|github\n' "$REPO" > "$WORK_CONF"
  C="$INFRA_ROOT/bin/console-collector"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  JOURNAL="$CONSOLE_STATE/events-$(date -u +%Y-%m-%d).jsonl"
  mkdir -p "$CONSOLE_STATE"
}

# ev <décalage en secondes> <event> <session> [tool] [summary] [tool_use_id] [result]
ev() {
  local ts; ts="$(date -u -d "-${1} seconds" +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg e "$2" --arg s "$3" --arg t "${4:-}" --arg sum "${5:-}" \
         --arg id "${6:-}" --arg r "${7:-}" --arg c "$REPO" \
    '{ts: $ts, event: $e, session: $s, cwd: $c, project: "app",
      tool: (if $t == "" then null else $t end),
      tool_use_id: (if $id == "" then null else $id end),
      summary: $sum, result: (if $r == "" then null else $r end)}' >> "$JOURNAL"
}

# session <id> <pid> : session vivante vue par le collecteur
session() {
  jq -n --arg id "$1" --argjson pid "$2" --arg cwd "$REPO" \
    '{sessionId: $id, pid: $pid, cwd: $cwd, kind: "interactive", startedAt: 1789000000000, name: $id}' \
    > "$CONSOLE_SESSIONS_DIR/$1.json"
  printf '#!/bin/bash\necho "  %s 1 100000 /usr/bin/claude"\n' "$2" > "$BIN/ps"
  chmod +x "$BIN/ps"
}

@test "activity : les derniers événements, du plus récent au plus ancien" {
  ev 30 PreToolUse s-1 Bash "git status" toolu_1
  ev 20 PostToolUse s-1 Bash "git status" toolu_1 ok
  ev 10 PreToolUse s-1 Edit "$REPO/src/x.php" toolu_2

  run "$C" once activity
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 5 and (.data | length) == 3
    and .data[0].tool == "Edit" and .data[0].project == "app"
    and .data[2].event == "PreToolUse"' >/dev/null
}

@test "activity : le journal de la veille est pris en compte, les plus vieux fichiers ignorés" {
  local hier avant
  hier="$CONSOLE_STATE/events-$(date -u -d '-1 day' +%Y-%m-%d).jsonl"
  avant="$CONSOLE_STATE/events-$(date -u -d '-9 days' +%Y-%m-%d).jsonl"
  jq -nc '{ts:"2026-09-15T10:00:00Z", event:"Stop", session:"s-hier", cwd:"/x", project:"app", tool:null, tool_use_id:null, summary:"", result:null}' > "$hier"
  jq -nc '{ts:"2026-09-07T10:00:00Z", event:"Stop", session:"s-vieux", cwd:"/x", project:"app", tool:null, tool_use_id:null, summary:"", result:null}' > "$avant"
  ev 5 Stop s-1

  run "$C" once activity
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '([.data[].session] | index("s-hier")) != null
    and ([.data[].session] | index("s-vieux")) == null' >/dev/null
}

@test "activity : purge des journaux de plus de 7 jours" {
  local vieux
  vieux="$CONSOLE_STATE/events-$(date -u -d '-9 days' +%Y-%m-%d).jsonl"
  echo '{}' > "$vieux"
  ev 5 Stop s-1

  "$C" once activity >/dev/null
  [ ! -f "$vieux" ]
  [ -f "$JOURNAL" ]
}

@test "activity : journal absent, section vide sans erreur" {
  rm -f "$JOURNAL"
  run "$C" once activity
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == []' >/dev/null
}

@test "sessions : statut « exécute » quand un outil est lancé sans résultat" {
  session s-1 4242
  ev 12 PreToolUse s-1 Bash "make test" toolu_1

  run "$C" once sessions
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.items[0].status == "executing"
    and (.data.items[0].status_detail | test("make test"))
    and .data.items[0].status_since_s >= 10' >/dev/null
}

@test "sessions : « travaille » une fois le résultat reçu" {
  session s-1 4242
  ev 12 PreToolUse s-1 Bash "make test" toolu_1
  ev 2 PostToolUse s-1 Bash "make test" toolu_1 ok

  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].status == "working"' >/dev/null
}

@test "sessions : « attend une réponse » sur Notification" {
  session s-1 4242
  ev 30 PreToolUse s-1 Bash "rm -rf /" toolu_1
  ev 5 Notification s-1 "" "Claude needs your permission to use Bash"

  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].status == "waiting"
    and (.data.items[0].status_detail | test("permission"))' >/dev/null
}

@test "sessions : « au repos » après Stop, et blocage de la garde signalé" {
  session s-1 4242
  ev 60 'guard.block' s-1 Edit "⛔ work · app : aucun ticket démarré"
  ev 20 Stop s-1

  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].status == "idle"
    and .data.items[0].last_block != null' >/dev/null
}

@test "sessions : sans journal, statut inconnu mais section valide" {
  session s-1 4242
  rm -f "$JOURNAL"

  run "$C" once sessions
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.items[0].status == "unknown"' >/dev/null
}
