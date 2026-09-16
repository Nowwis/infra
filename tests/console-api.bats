load helpers
setup() {
  setup_infra
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/bash\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  export WT_METRICS_BIN="$BIN/wt-metrics" WT_DASH_CACHE="$BATS_TEST_TMPDIR/cache.json"
  command -v php >/dev/null || skip "php not installed"
}

@test "metrics endpoint returns valid JSON with sections" {
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("sessions")' >/dev/null
}

@test "csv endpoint returns CSV header" {
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; echo wt_api_csv();'
  [[ "$output" == *","* ]]
}

@test "metrics endpoint caches: a second call within 2s does not re-invoke wt-metrics" {
  COUNTER="$BATS_TEST_TMPDIR/calls"
  printf '#!/bin/bash\necho x >> "%s"\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' "$COUNTER" > "$BIN/wt-metrics"
  chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; wt_api_metrics(); wt_api_metrics();'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COUNTER")" -eq 1 ]
}

@test "metrics endpoint refreshes the cache once it is older than ~2s" {
  COUNTER="$BATS_TEST_TMPDIR/calls2"
  printf '#!/bin/bash\necho x >> "%s"\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' "$COUNTER" > "$BIN/wt-metrics"
  chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; wt_api_metrics();'
  [ "$status" -eq 0 ]
  sleep 3
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; wt_api_metrics();'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COUNTER")" -eq 2 ]
}

@test "metrics endpoint degrades to a safe default when wt-metrics emits invalid JSON" {
  printf '#!/bin/bash\necho "not json"\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("sessions") and (has("worktrees")|not)' >/dev/null
}

@test "metrics endpoint degrades to a safe default when wt-metrics emits nothing" {
  printf '#!/bin/bash\ntrue\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("INFRA_ROOT")."/console/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("sessions") and (has("worktrees")|not)' >/dev/null
}

@test "router dispatches GET /api/metrics with JSON content type" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/metrics"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  echo "$output" | grep -o '{.*}' | jq -e 'has("system")' >/dev/null
}

@test "router dispatches GET /api/metrics.csv as CSV" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/metrics.csv"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *","* ]]
}

@test "router answers not found to the former POST destroy route" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/worktrees/x/destroy"; $_SERVER["REQUEST_METHOD"]="POST";
    require getenv("INFRA_ROOT")."/console/server/router.php";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -f "$INFRA_ROOT/console/server/destroy.php" ]
}

@test "router serves an existing static file from console/public by returning false" {
  mkdir -p "$INFRA_ROOT/console/public"
  echo hello > "$INFRA_ROOT/console/public/hello.txt"
  run php -r '
    $_SERVER["REQUEST_URI"]="/hello.txt"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);
  '
  rm -f "$INFRA_ROOT/console/public/hello.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(false)"* ]]
}

@test "router 404s an unknown static path" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/does-not-exist.txt"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "router refuses to serve outside console/public via path traversal" {
  SECRET="$BATS_TEST_TMPDIR/secret.txt"
  echo topsecret > "$SECRET"
  run php -r '
    $_SERVER["REQUEST_URI"]="/../../../../../../../../etc/passwd"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"root:"* ]]
}
