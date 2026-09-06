load helpers
setup() {
  setup_wt
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/bash\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  export WT_METRICS_BIN="$BIN/wt-metrics" WT_DASH_CACHE="$BATS_TEST_TMPDIR/cache.json"
  command -v php >/dev/null || skip "php not installed"
}

@test "metrics endpoint returns valid JSON with sections" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("sessions")' >/dev/null
}

@test "csv endpoint returns CSV header" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_csv();'
  [[ "$output" == *","* ]]
}

@test "metrics endpoint caches: a second call within 2s does not re-invoke wt-metrics" {
  COUNTER="$BATS_TEST_TMPDIR/calls"
  printf '#!/bin/bash\necho x >> "%s"\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' "$COUNTER" > "$BIN/wt-metrics"
  chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; wt_api_metrics(); wt_api_metrics();'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COUNTER")" -eq 1 ]
}

@test "metrics endpoint refreshes the cache once it is older than ~2s" {
  COUNTER="$BATS_TEST_TMPDIR/calls2"
  printf '#!/bin/bash\necho x >> "%s"\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' "$COUNTER" > "$BIN/wt-metrics"
  chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; wt_api_metrics();'
  [ "$status" -eq 0 ]
  sleep 3
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; wt_api_metrics();'
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COUNTER")" -eq 2 ]
}

@test "metrics endpoint degrades to a safe default when wt-metrics emits invalid JSON" {
  printf '#!/bin/bash\necho "not json"\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("worktrees") and has("sessions")' >/dev/null
}

@test "metrics endpoint degrades to a safe default when wt-metrics emits nothing" {
  printf '#!/bin/bash\ntrue\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("worktrees") and has("sessions")' >/dev/null
}

@test "router dispatches GET /api/metrics with JSON content type" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/metrics"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  echo "$output" | grep -o '{.*}' | jq -e 'has("system")' >/dev/null
}

@test "router dispatches GET /api/metrics.csv as CSV" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/metrics.csv"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *","* ]]
}

@test "router does not require destroy.php for a plain metrics GET" {
  # destroy.php's require lives inside the POST /destroy branch only, so a
  # plain metrics GET must never touch it (even now that Task 4 exists).
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/metrics"; $_SERVER["REQUEST_METHOD"]="GET";
    require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump(function_exists("wt_api_destroy"));
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(false)"* ]]
}

@test "router serves an existing static file from dashboard/public by returning false" {
  mkdir -p "$WT_ROOT/dashboard/public"
  echo hello > "$WT_ROOT/dashboard/public/hello.txt"
  run php -r '
    $_SERVER["REQUEST_URI"]="/hello.txt"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump($r);
  '
  rm -f "$WT_ROOT/dashboard/public/hello.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(false)"* ]]
}

@test "router 404s an unknown static path" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/does-not-exist.txt"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "router refuses to serve outside dashboard/public via path traversal" {
  SECRET="$BATS_TEST_TMPDIR/secret.txt"
  echo topsecret > "$SECRET"
  run php -r '
    $_SERVER["REQUEST_URI"]="/../../../../../../../../etc/passwd"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("WT_ROOT")."/dashboard/server/router.php";
    var_dump($r);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"root:"* ]]
}
