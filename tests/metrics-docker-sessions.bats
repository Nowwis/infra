load helpers
setup() {
  setup_wt; M="$WT_ROOT/bin/wt-metrics"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  # stub docker: `docker stats --no-stream --format {{json .}}` then `docker ps` label lookup
  cat > "$BIN/docker" <<'EOF'
#!/bin/bash
case "$*" in
  *"stats"*) printf '%s\n' '{"Name":"myapp-t1-php-1","CPUPerc":"3.50%","MemUsage":"120MiB / 2GiB","MemPerc":"5.86%"}';;
  *"inspect"*) echo "myapp-t1";;   # compose project label
  *) echo "";;
esac
EOF
  chmod +x "$BIN/docker"
  # stub wt list --json
  cat > "$BIN/wt" <<'EOF'
#!/bin/bash
[ "$1" = list ] && echo '[{"app":"myapp","slug":"t1","project":"myapp-t1","path":"'"$HOME"'/wt/myapp-t1","domain":"myapp-t1.docker.test"}]'
EOF
  chmod +x "$BIN/wt"; mkdir -p "$HOME/wt/myapp-t1"
  export WT_METRICS_WT="$BIN/wt"; export PATH="$BIN:$PATH"
}
@test "docker section maps name+project+cpu+mem" {
  run "$M" docker
  echo "$output" | jq -e 'type=="array" and (.[0].name=="myapp-t1-php-1") and (.[0].cpu_pct=="3.50%")' >/dev/null
}
@test "worktrees section enriches wt list with disk_bytes" {
  run "$M" worktrees
  echo "$output" | jq -e '.[0].project=="myapp-t1" and (.[0]|has("disk_bytes"))' >/dev/null
}
@test "sessions section returns an array with group/cwd/name keys" {
  run "$M" sessions
  echo "$output" | jq -e 'type=="array"' >/dev/null
  # chaque session porte les clés de lotissement (vrai vide si aucun process)
  echo "$output" | jq -e 'all(.[]; has("group") and has("cwd") and has("name"))' >/dev/null
}
