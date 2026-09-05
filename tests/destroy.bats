load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  export WT_DRY_RUN=1 WT_YES=1
  wt_reg_add '{"project":"myprojekt-app-gel-123","app":"myprojekt-app","slug":"gel-123","path":"'"$HOME"'/wt/myprojekt-app-gel-123","branch":"feature/gel-123","db":"myprojekt_app_gel_123","domain":"myprojekt-app-gel-123.docker.test"}'
  mkdir -p "$HOME/wt/myprojekt-app-gel-123"
}
@test "destroy emits down -> drop db -> worktree remove and clears registry" {
  run wt destroy myprojekt-app gel-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"down -v"* ]]
  [[ "$output" == *"DROP DATABASE IF EXISTS \`myprojekt_app_gel_123\`"* ]]
}
@test "destroy refuses unknown env" {
  run wt destroy myprojekt-app nope; [ "$status" -ne 0 ]; [[ "$output" == *"not managed"* ]]
}
