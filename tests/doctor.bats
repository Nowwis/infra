load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  # entry whose path does not exist -> MISSING-DIR
  wt_reg_add '{"project":"app-gone","app":"app","slug":"gone","path":"'"$HOME"'/wt/app-gone","db":"app_gone","domain":"app-gone.docker.test","branch":"feature/gone"}'
}
@test "doctor flags a registry entry with no worktree dir" {
  run wt doctor
  [[ "$output" == *"MISSING-DIR app-gone"* ]]
}
@test "doctor --fix drops the stale entry" {
  run wt doctor --fix
  run wt list --json
  [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
}
