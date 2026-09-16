load helpers

setup() {
  setup_infra
  export CONSOLE_SNAPSHOT="$BATS_TEST_TMPDIR/snapshot.json"
  command -v php >/dev/null || skip "php not installed"
}

# snap [âge en secondes] [nom de conteneur]
snap() {
  jq -n --argjson t "$(( $(date +%s) - ${1:-0} ))" --arg cname "${2:-app-php-1}" '{
    generated_at: $t,
    sections: {
      system: {collected_at: $t, cadence: 2, data: {mem_total_kb: 16000000, mem_avail_kb: 8000000,
        swap_total_kb: 8000000, swap_used_kb: 0, load1: 1.5, ncpu: 4,
        psi: {cpu_some_avg10: 1, mem_some_avg60: 0, mem_full_avg60: 0, io_some_avg60: 0}, oom_kill_total: 27}},
      disk: {collected_at: $t, cadence: 60, data: [{mount: "/", size: 100, used: 50, avail: 50, use_pct: 50}]},
      docker: {collected_at: $t, cadence: 15, data: [{name: $cname, project: "app", state: "running",
        cpu_pct: "3.50%", mem_used: "120MiB", restarts: 0, health: null}]},
      sessions: {collected_at: $t, cadence: 5, data: {items: [{session_id: "s1", pid: 1, project: "app",
        tmux: "app", rss_kb: 1000, mcp: [], ticket: "GEL-1", name: "app-x", age_s: 60, system: false}], mcp_orphans: []}},
      projects: {collected_at: $t, cadence: 10, data: [{name: "app", state: "free", dirty: 0, drift: [], pending_prs: []}]},
      diagnostics: {collected_at: $t, cadence: 15, data: [{id: "ram", level: "warn", title: "Mémoire faible",
        detail: "12 % disponibles", action: "Fermer des sessions"}]}
    }}' > "$CONSOLE_SNAPSHOT"
}

api() { php -r "require getenv('INFRA_ROOT').'/console/server/api.php'; echo $1;"; }

@test "snapshot : sections servies, fraîcheur calculée" {
  snap
  run api 'console_api_snapshot()'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.sections | keys | length) == 6
    and .sections.system.stale == false and .sections.diagnostics.data[0].id == "ram"
    and (.missing | not)' >/dev/null
}

@test "snapshot : section périmée marquée stale" {
  snap 600
  run api 'console_api_snapshot()'
  echo "$output" | jq -e '.sections.system.stale == true and .sections.disk.stale == true' >/dev/null
}

@test "snapshot absent ou illisible : réponse sûre" {
  rm -f "$CONSOLE_SNAPSHOT"
  run api 'console_api_snapshot()'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.missing == true and .sections == {} and .generated_at == null' >/dev/null

  echo 'pas du json' > "$CONSOLE_SNAPSHOT"
  run api 'console_api_snapshot()'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.missing == true' >/dev/null
}

@test "CSV : en-tête, lignes par section, injection de formule neutralisée" {
  snap 0 '=cmd()'
  run api 'console_api_csv()'
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "section,key,value" ]]
  [[ "$output" == *"system,mem_total_kb,16000000"* ]]
  [[ "$output" == *"disk,/"* ]]
  [[ "$output" == *"'=cmd()"* ]]
  [[ "$output" == *"diagnostics,ram"* ]]
}

@test "l'API ne lance aucune commande" {
  run grep -c 'shell_exec\|exec(\|passthru\|popen\|proc_open' "$INFRA_ROOT/console/server/api.php"
  [ "$output" = 0 ]
}

@test "router : /api/snapshot en JSON" {
  snap
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/snapshot"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);'
  [ "$status" -eq 0 ]
  [[ "$output" == *"bool(true)"* ]]
  echo "$output" | grep -o '{.*}' | jq -e '.sections.system.cadence == 2' >/dev/null
}

@test "router : /api/snapshot.csv en CSV" {
  snap
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/snapshot.csv"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);'
  [ "$status" -eq 0 ]
  [[ "$output" == *"section,key,value"* ]]
}

@test "router : anciennes routes et POST refusés" {
  for uri in /api/metrics /api/worktrees/x/destroy; do
    run php -r "
      \$_SERVER['REQUEST_URI']='$uri'; \$_SERVER['REQUEST_METHOD']='POST';
      require getenv('INFRA_ROOT').'/console/server/router.php';"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
  done
}

@test "router : fichier statique servi, chemin inconnu en 404, traversée refusée" {
  echo hello > "$INFRA_ROOT/console/public/hello.txt"
  run php -r '
    $_SERVER["REQUEST_URI"]="/hello.txt"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);'
  rm -f "$INFRA_ROOT/console/public/hello.txt"
  [[ "$output" == *"bool(false)"* ]]

  run php -r '
    $_SERVER["REQUEST_URI"]="/../../../../etc/passwd"; $_SERVER["REQUEST_METHOD"]="GET";
    $r = require getenv("INFRA_ROOT")."/console/server/router.php";
    var_dump($r);'
  [[ "$output" == *"not found"* ]]
  [[ "$output" != *"root:"* ]]
}
