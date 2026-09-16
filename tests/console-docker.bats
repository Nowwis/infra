load helpers

setup() {
  setup_infra
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  export WORK_CONF="$BATS_TEST_TMPDIR/projects.conf"
  printf 'conso-work|/home/x/Project/2JDB/stream.consotrust.com|main|develop|gitlab\n' > "$WORK_CONF"
  C="$INFRA_ROOT/bin/console-collector"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
}

stub_docker() {
  cat > "$BIN/docker" <<'EOF'
#!/bin/bash
case "$*" in
  *"ps -aq"*)
    cat <<'OUT'
id1
id2
id3
OUT
    ;;
  *"ps -a --format"*)
    cat <<'OUT'
consotrust-php-1	running	Up 6 hours	consotrust	/home/x/Project/2JDB/stream.consotrust.com/.docker
bifacto-doc-nodejs-1	running	Up 2 days (healthy)	bifacto-doc	/home/x/Project/Diplam09/doc.bifacto.com/.docker
orphan-1	exited	Exited (137) 2 weeks ago
OUT
    ;;
  *"stats --no-stream"*)
    cat <<'OUT'
consotrust-php-1	3.50%	120MiB / 2GiB	5.86%
bifacto-doc-nodejs-1	0.10%	50MiB / 2GiB	2.44%
OUT
    ;;
  *inspect*)
    cat <<'OUT'
/consotrust-php-1	0
/bifacto-doc-nodejs-1	2	healthy
/orphan-1	5
OUT
    ;;
  *"system df"*)
    cat <<'OUT'
{"Type":"Images","Size":"43.51GB","Reclaimable":"1.454GB (3%)","TotalCount":"81","Active":"42"}
{"Type":"Containers","Size":"5.546GB","Reclaimable":"2.769GB (49%)","TotalCount":"50","Active":"45"}
OUT
    ;;
esac
EOF
  chmod +x "$BIN/docker"
}

@test "docker : jointure ps/stats/inspect, santé, redémarrages" {
  stub_docker
  run "$C" once docker
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 15 and (.data | length) == 3
    and .data[0].name == "consotrust-php-1" and .data[0].state == "running"
    and .data[0].cpu_pct == "3.50%" and .data[0].mem_used == "120MiB"
    and .data[0].restarts == 0 and .data[0].health == null
    and .data[1].health == "healthy" and .data[1].restarts == 2' >/dev/null
}

@test "docker : un conteneur est rattaché au projet work qui contient son working_dir" {
  stub_docker
  run "$C" once docker
  echo "$output" | jq -e '.data[0].project == "conso-work" and .data[0].compose_project == "consotrust"' >/dev/null
  # hors projet work : on retombe sur le projet compose
  echo "$output" | jq -e '.data[1].project == "bifacto-doc"' >/dev/null
}

@test "docker : conteneur arrêté sans statistiques ni projet" {
  stub_docker
  run "$C" once docker
  echo "$output" | jq -e '.data[2].name == "orphan-1" and .data[2].state == "exited"
    and .data[2].cpu_pct == null and .data[2].restarts == 5
    and .data[2].compose_project == null and .data[2].project == "orphan-1"' >/dev/null
}

@test "docker indisponible : section vide, jamais d'erreur" {
  printf '#!/bin/bash\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
  run "$C" once docker
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == []' >/dev/null
}

@test "docker_df : types, tailles et récupérable" {
  stub_docker
  run "$C" once docker_df
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 600 and (.data | length) == 2
    and .data[0].type == "Images" and .data[0].size == "43.51GB"
    and .data[0].reclaimable == "1.454GB (3%)" and .data[0].total == "81"' >/dev/null
}
