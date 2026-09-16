load helpers

setup() {
  setup_infra
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  export CONSOLE_PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$CONSOLE_PROC/pressure"
  cat > "$CONSOLE_PROC/meminfo" <<'EOF'
MemTotal:       16000000 kB
MemFree:         1000000 kB
MemAvailable:    4000000 kB
SwapTotal:       8000000 kB
SwapFree:        6000000 kB
EOF
  echo "1.50 1.20 1.10 2/2000 123" > "$CONSOLE_PROC/loadavg"
  printf 'some avg10=3.31 avg60=4.06 avg300=3.81 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$CONSOLE_PROC/pressure/cpu"
  printf 'some avg10=1.00 avg60=12.50 avg300=3.00 total=1\nfull avg10=0.50 avg60=6.25 avg300=1.00 total=0\n' > "$CONSOLE_PROC/pressure/memory"
  printf 'some avg10=0.10 avg60=22.00 avg300=5.00 total=1\nfull avg10=0.00 avg60=11.00 avg300=2.00 total=0\n' > "$CONSOLE_PROC/pressure/io"
  printf 'nr_free_pages 1000\noom_kill 27\n' > "$CONSOLE_PROC/vmstat"
  C="$INFRA_ROOT/bin/console-collector"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
}

stub_df() {
  cat > "$BIN/df" <<'EOF'
#!/bin/bash
cat <<'OUT'
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/sda1        202051056 138257960  63776712      69% /
tmpfs              1600000      1000   1599000       1% /run
OUT
EOF
  chmod +x "$BIN/df"
}

@test "once system : mémoire, swap, charge, PSI et compteur OOM" {
  run "$C" once system
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 2 and (.collected_at | type) == "number"
    and .data.mem_total_kb == 16000000 and .data.mem_avail_kb == 4000000
    and .data.swap_total_kb == 8000000 and .data.swap_used_kb == 2000000
    and .data.load1 == 1.5 and (.data.ncpu | type) == "number"
    and .data.psi.cpu_some_avg10 == 3.31 and .data.psi.mem_some_avg60 == 12.5
    and .data.psi.mem_full_avg60 == 6.25 and .data.psi.io_some_avg60 == 22
    and .data.oom_kill_total == 27' >/dev/null
}

@test "once écrit un fichier de section, sans laisser de fichier temporaire" {
  "$C" once system >/dev/null
  jq -e '.data.mem_total_kb == 16000000' "$CONSOLE_STATE/sections/system.json" >/dev/null
  run bash -c "ls '$CONSOLE_STATE/sections' | grep -c tmp"
  [ "$output" = 0 ]
}

@test "once disk : montages avec pourcentage numérique" {
  stub_df
  run "$C" once disk
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 60 and (.data | length) == 2
    and .data[0].mount == "/" and .data[0].use_pct == 69 and .data[0].used == 138257960
    and .data[1].mount == "/run"' >/dev/null
}

@test "une source en échec donne une section par défaut, jamais une erreur" {
  rm -f "$CONSOLE_PROC/meminfo"
  run "$C" once system
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.mem_total_kb == 0' >/dev/null

  printf '#!/bin/bash\nexit 1\n' > "$BIN/df"; chmod +x "$BIN/df"
  run "$C" once disk
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == []' >/dev/null
}

@test "assemble regroupe les sections présentes avec leur cadence" {
  stub_df
  "$C" once system >/dev/null
  "$C" once disk >/dev/null

  run "$C" assemble
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.generated_at | type) == "number"
    and (.sections | keys) == ["disk", "system"]
    and .sections.system.cadence == 2 and .sections.disk.data[0].mount == "/"' >/dev/null
  jq -e '.sections.system.data.oom_kill_total == 27' "$CONSOLE_STATE/snapshot.json" >/dev/null
}

@test "section inconnue et appel sans commande : erreurs explicites" {
  run "$C" once bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *bogus* ]]
  run "$C"
  [ "$status" -ne 0 ]
}

@test "run collecte toutes les sections au démarrage puis s'arrête après CONSOLE_RUN_TICKS" {
  stub_df
  # Isolation : aucune vraie source (projets, docker, processus, systemd, gh).
  export WORK_CONF="$BATS_TEST_TMPDIR/projects.conf"; : > "$WORK_CONF"
  export CONSOLE_SESSIONS_DIR="$BATS_TEST_TMPDIR/sessions"; mkdir -p "$CONSOLE_SESSIONS_DIR"
  local c
  for c in docker gh systemctl; do printf '#!/bin/bash\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
  printf '#!/bin/bash\necho "  1 0 100 /sbin/init"\n' > "$BIN/ps"; chmod +x "$BIN/ps"

  CONSOLE_RUN_TICKS=2 run "$C" run
  [ "$status" -eq 0 ]
  jq -e '.data.mem_total_kb == 16000000' "$CONSOLE_STATE/sections/system.json" >/dev/null
  jq -e '.data[0].mount == "/"' "$CONSOLE_STATE/sections/disk.json" >/dev/null
  jq -e '(.sections | has("system")) and (.sections | has("disk"))
     and (.sections | has("docker")) and (.sections | has("sessions"))
     and (.sections | has("projects")) and (.sections | has("diagnostics"))
     and .sections.system.data.mem_total_kb == 16000000
     and .sections.projects.data == []' "$CONSOLE_STATE/snapshot.json" >/dev/null
}
