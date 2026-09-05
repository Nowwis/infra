load helpers
setup() {
  setup_wt
  export WT_DASH_UNIT_DIR="$BATS_TEST_TMPDIR/systemd" WT_DASH_TRAEFIK="$BATS_TEST_TMPDIR/dynamic.yaml" WT_DASH_RELOAD=true
  printf 'http:\n  routers: {}\n  services: {}\n' > "$WT_DASH_TRAEFIK"
}
@test "install writes a systemd unit running php -S with the router" {
  run "$WT_ROOT/bin/wt-dash-install"; [ "$status" -eq 0 ]
  grep -q 'php -S' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
  grep -q 'router.php' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
}
@test "install adds a traefik router for worktree.docker.test idempotently" {
  "$WT_ROOT/bin/wt-dash-install"
  grep -q 'worktree.docker.test' "$WT_DASH_TRAEFIK"
  before="$(cat "$WT_DASH_TRAEFIK")"; "$WT_ROOT/bin/wt-dash-install"
  [ "$(cat "$WT_DASH_TRAEFIK")" = "$before" ]   # idempotent
}
@test "uninstall removes the unit and the traefik router" {
  "$WT_ROOT/bin/wt-dash-install"
  run "$WT_ROOT/bin/wt-dash-install" --uninstall; [ "$status" -eq 0 ]
  [ ! -f "$WT_DASH_UNIT_DIR/wt-dashboard.service" ]
  ! grep -q 'wt-dashboard' "$WT_DASH_TRAEFIK"
}
