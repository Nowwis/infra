load helpers

setup() {
  setup_infra
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  C="$INFRA_ROOT/bin/console-collector"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
  printf '#!/bin/bash\nexit 0\n' > "$BIN/systemctl"; chmod +x "$BIN/systemctl"
  healthy
}

# sec <nom> <cadence> <data JSON> [âge en secondes]
sec() {
  mkdir -p "$CONSOLE_STATE/sections"
  jq -n --argjson c "$2" --argjson d "$3" --argjson t "$(( $(date +%s) - ${4:-0} ))" \
    '{collected_at: $t, cadence: $c, data: $d}' > "$CONSOLE_STATE/sections/$1.json"
}

healthy() {
  sec system 2 '{"mem_total_kb":16000000,"mem_avail_kb":8000000,"swap_total_kb":8000000,"swap_used_kb":1000000,
                 "load1":1.5,"ncpu":4,"psi":{"cpu_some_avg10":3.3,"mem_some_avg60":0.0,"mem_full_avg60":0.0,"io_some_avg60":0.1},
                 "oom_kill_total":27}'
  sec disk 60 '[{"mount":"/","size":100,"used":50,"avail":50,"use_pct":50}]'
  sec docker 15 '[{"name":"app-php-1","project":"app","state":"running","health":null,"restarts":0}]'
  sec sessions 5 '{"items":[],"mcp_orphans":[]}'
  sec projects 10 '[{"name":"app","state":"free","drift":[],"pending_prs":[]}]'
}

level_of() { echo "$output" | jq -r --arg id "$1" '.data[] | select(.id == $id) | .level'; }

@test "système sain : aucun diagnostic" {
  run "$C" once diagnostics
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 15 and .data == []' >/dev/null
}

@test "mémoire, swap et pressions" {
  sec system 2 '{"mem_total_kb":16000000,"mem_avail_kb":1000000,"swap_total_kb":8000000,"swap_used_kb":5000000,
                 "load1":9,"ncpu":4,"psi":{"cpu_some_avg10":50,"mem_some_avg60":30,"mem_full_avg60":10,"io_some_avg60":25},
                 "oom_kill_total":27}'
  run "$C" once diagnostics
  [ "$status" -eq 0 ]
  [ "$(level_of ram)" = crit ]
  [ "$(level_of swap)" = warn ]
  [ "$(level_of psi-memory)" = crit ]
  [ "$(level_of psi-io)" = warn ]
  echo "$output" | jq -e '.data[] | select(.id == "ram") | (.title | length) > 0 and (.action | length) > 0' >/dev/null
}

@test "disque : un diagnostic par point de montage au-delà du seuil" {
  sec disk 60 '[{"mount":"/","size":100,"used":90,"avail":10,"use_pct":90},
                {"mount":"/var","size":100,"used":97,"avail":3,"use_pct":97},
                {"mount":"/run","size":100,"used":1,"avail":99,"use_pct":1}]'
  run "$C" once diagnostics
  [ "$(level_of 'disk:/')" = warn ]
  [ "$(level_of 'disk:/var')" = crit ]
  [ -z "$(level_of 'disk:/run')" ]
}

@test "OOM : seule une hausse depuis 24 h est signalée" {
  printf '%s 20\n' "$(( $(date +%s) - 90000 ))" > "$CONSOLE_STATE/oom_history"
  run "$C" once diagnostics
  [ "$(level_of oom)" = warn ]
  echo "$output" | jq -e '.data[] | select(.id == "oom") | .detail | test("7")' >/dev/null

  printf '%s 27\n' "$(( $(date +%s) - 90000 ))" > "$CONSOLE_STATE/oom_history"
  run "$C" once diagnostics
  [ -z "$(level_of oom)" ]
}

@test "docker : conteneur en mauvaise santé et redémarrages récents" {
  sec docker 15 '[{"name":"a-php-1","project":"a","state":"running","health":"unhealthy","restarts":0},
                  {"name":"b-php-1","project":"b","state":"running","health":"healthy","restarts":5}]'
  printf '{"b-php-1":1}' > "$CONSOLE_STATE/docker_restarts.json"
  run "$C" once diagnostics
  [ "$(level_of 'docker-health:a-php-1')" = warn ]
  [ "$(level_of 'docker-restarts:b-php-1')" = crit ]
}

@test "systemd : unités en échec, init.scope ignorée" {
  printf '#!/bin/bash\ncat <<OUT\ninit.scope loaded failed failed System and Service Manager\nconsole-collector.service loaded failed failed Console collector\nOUT\n' > "$BIN/systemctl"
  chmod +x "$BIN/systemctl"
  run "$C" once diagnostics
  [ "$(level_of systemd-failed)" = warn ]
  echo "$output" | jq -e '.data[] | select(.id == "systemd-failed") | (.detail | test("console-collector")) and (.detail | test("init.scope") | not)' >/dev/null
}

@test "MCP orphelins et verrou work orphelin" {
  sec sessions 5 '{"items":[],"mcp_orphans":[{"command":"node a-mcp","count":4},{"command":"node b-mcp","count":8}]}'
  sec projects 10 '[{"name":"app","state":"active","ticket":"GEL-1","branch":"feature/GEL-1","drift":["verrou-orphelin"],"pending_prs":[]}]'
  run "$C" once diagnostics
  [ "$(level_of mcp-orphans)" = crit ]
  [ "$(level_of 'work-lock:app')" = warn ]
  echo "$output" | jq -e '.data[] | select(.id == "work-lock:app") | .detail | test("GEL-1")' >/dev/null
}

@test "section absente ou périmée : source indisponible" {
  rm -f "$CONSOLE_STATE/sections/docker.json"
  sec sessions 5 '{"items":[],"mcp_orphans":[]}' 600
  run "$C" once diagnostics
  [ "$(level_of 'source:docker')" = warn ]
  [ "$(level_of 'source:sessions')" = warn ]
  [ -z "$(level_of 'source:system')" ]
}
