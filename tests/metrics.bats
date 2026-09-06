load helpers
setup() { setup_wt; M="$WT_ROOT/bin/wt-metrics"; }
@test "system emits valid JSON with numeric mem/swap/ncpu" {
  run "$M" system
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("mem_total_kb") and has("swap_total_kb") and (.ncpu|type=="number")' >/dev/null
}
@test "disk emits a JSON array of mounts" {
  run "$M" disk
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type=="array" and (length>=1) and (.[0]|has("mount") and has("use_pct"))' >/dev/null
}
@test "all emits an object with the five sections" {
  run "$M" all
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("worktrees") and has("sessions")' >/dev/null
}
@test "unknown section fails" { run "$M" bogus; [ "$status" -ne 0 ]; }
