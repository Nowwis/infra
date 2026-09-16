load helpers
setup() {
  setup_infra
  command -v php >/dev/null || skip "php not installed"
}

@test "router serves index.html for /" {
  # boot php -S on an ephemeral port, curl /, then kill it
  PORT=8912
  php -S 127.0.0.1:$PORT -t "$INFRA_ROOT/console/public" "$INFRA_ROOT/console/server/router.php" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  run curl -s "http://127.0.0.1:$PORT/"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
  [[ "$output" == *'<section id="system"'* ]]
}
