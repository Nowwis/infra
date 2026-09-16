load helpers
setup() {
  setup_infra
  export CONSOLE_UNIT_DIR="$BATS_TEST_TMPDIR/systemd"
  export CONSOLE_HTPASSWD_FILE="$BATS_TEST_TMPDIR/console.htpasswd"
  export CONSOLE_RELOAD=true
}

@test "install écrit l'unité console-web qui lance php -S avec le router" {
  CONSOLE_PASSWORD=secret run "$INFRA_ROOT/bin/console-install"
  [ "$status" -eq 0 ]
  grep -q 'php -S' "$CONSOLE_UNIT_DIR/console-web.service"
  grep -q 'console/server/router.php' "$CONSOLE_UNIT_DIR/console-web.service"
}

@test "install génère un secret htpasswd, conservé à la relance" {
  CONSOLE_PASSWORD=secret "$INFRA_ROOT/bin/console-install"
  grep -qE '^admin:' "$CONSOLE_HTPASSWD_FILE"
  before="$(cat "$CONSOLE_HTPASSWD_FILE")"
  CONSOLE_PASSWORD=secret "$INFRA_ROOT/bin/console-install"
  [ "$(cat "$CONSOLE_HTPASSWD_FILE")" = "$before" ]
}

@test "CONSOLE_HTPASSWD explicite fait tourner le secret" {
  CONSOLE_PASSWORD=secret "$INFRA_ROOT/bin/console-install"
  CONSOLE_HTPASSWD='admin:$apr1$xxxx$yyyy' run "$INFRA_ROOT/bin/console-install"
  [ "$status" -eq 0 ]
  grep -q 'apr1[$]xxxx' "$CONSOLE_HTPASSWD_FILE"
}

@test "sans mot de passe ni secret existant : échec explicite" {
  run "$INFRA_ROOT/bin/console-install"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONSOLE_PASSWORD"* ]]
}

@test "uninstall retire l'unité et le secret" {
  CONSOLE_PASSWORD=secret "$INFRA_ROOT/bin/console-install"
  run "$INFRA_ROOT/bin/console-install" --uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$CONSOLE_UNIT_DIR/console-web.service" ]
  [ ! -f "$CONSOLE_HTPASSWD_FILE" ]
}
