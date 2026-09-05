load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  wt_reg_add '{"project":"app-x","app":"app","slug":"x","path":"'"$HOME"'/wt/app-x","branch":"feature/x","domain":"app-x.docker.test","db":"app_x"}'
  mkdir -p "$HOME/wt/app-x"
}
@test "list --json returns the registry array" {
  run wt list --json; [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
}
@test "list table shows domain" {
  run wt list; [[ "$output" == *"app-x.docker.test"* ]]
}
@test "open prints the path" {
  run wt open app x; [ "$status" -eq 0 ]; [[ "$output" == *"/wt/app-x"* ]]
}
@test "open fails on missing env" {
  run wt open app nope; [ "$status" -ne 0 ]
}
