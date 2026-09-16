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
}

# session <id> <pid> <cwd> [tmux] [nom]
session() {
  jq -n --arg id "$1" --argjson pid "$2" --arg cwd "$3" --arg tmux "${4:-}" --arg name "${5:-$1}" \
    '{sessionId: $id, pid: $pid, cwd: $cwd, kind: "interactive", entrypoint: "sdk-cli",
      startedAt: 1789000000000, name: $name} + (if $tmux == "" then {} else {tmux: $tmux} end)' \
    > "$CONSOLE_SESSIONS_DIR/$1.json"
}

# ps simulé : pid, ppid, rss, commande
stub_ps() {
  cat > "$BIN/ps" <<'EOF'
#!/bin/bash
cat <<'OUT'
  101     1 150000 /usr/bin/claude --session s-live
  111   101  60000 node /home/u/.npm/mcp-server-gsc/index.js
  112   101  40000 /usr/bin/node /home/u/.claude/plugins/claude-mem/scripts/mcp-server.cjs
  102     1  90000 /usr/bin/claude observer
  113   102  30000 node /home/u/observer-mcp.js
  900     1  70000 node /home/u/orphelin/mcp-server-gsc/index.js
  901     1  20000 /usr/bin/php -S 127.0.0.1:8899
OUT
EOF
  chmod +x "$BIN/ps"
}

@test "sessions : seules les vivantes, avec projet, tmux, nom et RSS de l'arbre" {
  stub_ps
  session s-live 101 "$REPO" app-tmux app-x
  session s-dead 999999 "$REPO"

  run "$C" once sessions
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 5 and (.data.items | length) == 1
    and .data.items[0].session_id == "s-live" and .data.items[0].pid == 101
    and .data.items[0].project == "app" and .data.items[0].tmux == "app-tmux"
    and .data.items[0].name == "app-x" and .data.items[0].rss_kb == 250000
    and .data.items[0].system == false and (.data.items[0].age_s | type) == "number"
    and (.data.items[0].mcp | length) == 2' >/dev/null
}

@test "sessions : une session interne claude-mem est marquée système" {
  stub_ps
  session s-sys 102 "$HOME/.claude-mem/observer-sessions"

  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].system == true and .data.items[0].project == null' >/dev/null
}

@test "sessions : le ticket tenu par la session est remonté" {
  stub_ps
  session s-live 101 "$REPO"
  jq -n '{state: "active", ticket: "GEL-7", branch: "feature/GEL-7", owner_session: "s-live", pending_prs: []}' \
    > "$REPO/.git/claude-work.json"

  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].ticket == "GEL-7"' >/dev/null

  jq -n '{state: "active", ticket: "GEL-7", branch: "feature/GEL-7", owner_session: "autre", pending_prs: []}' \
    > "$REPO/.git/claude-work.json"
  run "$C" once sessions
  echo "$output" | jq -e '.data.items[0].ticket == null' >/dev/null
}

@test "sessions : serveurs MCP orphelins groupés par commande" {
  stub_ps
  session s-live 101 "$REPO"
  session s-sys 102 "$HOME/.claude-mem/observer-sessions"

  run "$C" once sessions
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.mcp_orphans | length) == 1
    and .data.mcp_orphans[0].count == 1
    and (.data.mcp_orphans[0].command | test("orphelin"))' >/dev/null
}

@test "sessions : aucune session vivante" {
  stub_ps
  session s-dead 999999 "$REPO"

  run "$C" once sessions
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.items == [] and (.data.mcp_orphans | length) >= 1' >/dev/null
}
