load helpers
setup() {
  setup_wt
  export WT_APPS_FILE="$WT_ROOT/tests/fixtures/apps.conf"
  # NOTE: deliberately NO WT_ENV_FILE — Ruling E means dry-run must not need
  # the MYSQL_ROOT_PASSWORD source. WT_ENV_FILE from the outer env would defeat
  # that check, so clear it.
  unset WT_ENV_FILE
}

# line number of the first output line matching a pattern (empty if none)
_lineno() { printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1; }

@test "create --dry-run emits an ordered plan and performs no real mutation" {
  run wt create myprojekt-app GEL-123 --feature --dry-run
  [ "$status" -eq 0 ]

  # required plan markers
  [[ "$output" == *"worktree add"* ]]
  [[ "$output" == *"CREATE DATABASE"* ]]
  [[ "$output" == *"compose -p myprojekt-app-gel-123"* ]]
  [[ "$output" == *"myprojekt-app-gel-123.docker.test"* ]]
  [[ "$output" == *"make install"* ]]
  # runtime-file provisioning is planned (.mcp.json / .env.test.local scoped to worktree)
  [[ "$output" == *".mcp.json"* ]]

  # ordering: worktree add < CREATE DATABASE < compose up
  local wa cd cu
  wa="$(_lineno 'worktree add')"
  cd="$(_lineno 'CREATE DATABASE')"
  cu="$(_lineno 'compose -p myprojekt-app-gel-123')"
  [ -n "$wa" ] && [ -n "$cd" ] && [ -n "$cu" ]
  [ "$wa" -lt "$cd" ]
  [ "$cd" -lt "$cu" ]

  # Ruling D: no real filesystem / registry mutation in dry-run
  [ ! -d "$HOME/wt/myprojekt-app-gel-123" ]
  if [ -f "$WT_STATE/registry.json" ]; then
    ! grep -q 'myprojekt-app-gel-123' "$WT_STATE/registry.json"
  fi
}

@test "create rejects an already-registered env" {
  # pre-register the target project
  source "$WT_ROOT/lib/registry.sh"
  wt_reg_add '{"project":"myprojekt-app-gel-123","app":"myprojekt-app","slug":"gel-123"}'
  run wt create myprojekt-app GEL-123 --feature --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}
