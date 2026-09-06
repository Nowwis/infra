load helpers
setup() {
  setup_wt
  export WT_DASH_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
  export WT_DASH_HTPASSWD_FILE="$BATS_TEST_TMPDIR/wt-dashboard.htpasswd"
  export WT_DASH_RELOAD=true
}

@test "install writes a systemd unit running php -S with the router" {
  WT_DASH_PASSWORD=secret run "$WT_ROOT/bin/wt-dash-install"; [ "$status" -eq 0 ]
  grep -q 'php -S' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
  grep -q 'router.php' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
}

@test "install generates an htpasswd secret, idempotent on re-run" {
  WT_DASH_PASSWORD=secret "$WT_ROOT/bin/wt-dash-install"
  grep -qE '^admin:' "$WT_DASH_HTPASSWD_FILE"
  before="$(cat "$WT_DASH_HTPASSWD_FILE")"
  WT_DASH_PASSWORD=secret "$WT_ROOT/bin/wt-dash-install"   # re-run keeps existing secret
  [ "$(cat "$WT_DASH_HTPASSWD_FILE")" = "$before" ]
}

@test "explicit WT_DASH_HTPASSWD rotates the secret" {
  WT_DASH_PASSWORD=secret "$WT_ROOT/bin/wt-dash-install"
  WT_DASH_HTPASSWD='admin:$apr1$xxxx$yyyy' run "$WT_ROOT/bin/wt-dash-install"; [ "$status" -eq 0 ]
  grep -q 'apr1[$]xxxx' "$WT_DASH_HTPASSWD_FILE"
}

@test "no password and no existing secret fails clearly" {
  run "$WT_ROOT/bin/wt-dash-install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WT_DASH_PASSWORD"* ]]
}

@test "install does NOT touch any Traefik dynamic_conf (route is committed)" {
  WT_DASH_PASSWORD=secret "$WT_ROOT/bin/wt-dash-install"
  # the installer must not create/rewrite a dynamic_conf; it only owns unit + secret
  [ ! -e "$BATS_TEST_TMPDIR/dynamic.yaml" ]
}

@test "uninstall removes the unit and the secret" {
  WT_DASH_PASSWORD=secret "$WT_ROOT/bin/wt-dash-install"
  run "$WT_ROOT/bin/wt-dash-install" --uninstall; [ "$status" -eq 0 ]
  [ ! -f "$WT_DASH_UNIT_DIR/wt-dashboard.service" ]
  [ ! -f "$WT_DASH_HTPASSWD_FILE" ]
}
