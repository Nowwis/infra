load helpers
setup() {
  setup_wt
  command -v php >/dev/null || skip "php not installed"
}

@test "wt-metrics all is valid JSON with all sections" {
  run "$WT_ROOT/bin/wt-metrics" all
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("docker") and has("worktrees") and has("sessions") and has("disk")' >/dev/null
}

@test "router serves index.html for /" {
  # boot php -S on an ephemeral port, curl /, then kill it
  PORT=8912
  php -S 127.0.0.1:$PORT -t "$WT_ROOT/dashboard/public" "$WT_ROOT/dashboard/server/router.php" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  run curl -s "http://127.0.0.1:$PORT/"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
  [[ "$output" == *'<section id="system"'* ]]
}
