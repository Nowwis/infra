load helpers
setup() { setup_wt; source "$WT_ROOT/lib/naming.sh"; source "$WT_ROOT/lib/envgen.sh"; }

@test "docker env gets new project + domain" {
  wt_gen_docker_env "$WT_ROOT/tests/fixtures/dot.docker.env" "$BATS_TEST_TMPDIR/.env" myprojekt-app-gel-123 myprojekt-app-gel-123.docker.test
  grep -qx 'COMPOSE_PROJECT_NAME=myprojekt-app-gel-123' "$BATS_TEST_TMPDIR/.env"
  grep -qx 'COMPOSE_PROJECT_DOMAIN=myprojekt-app-gel-123.docker.test' "$BATS_TEST_TMPDIR/.env"
  grep -q 'PROJECT_TYPE=symfony' "$BATS_TEST_TMPDIR/.env"
}
@test "env.local repoints app_url and database_url" {
  wt_patch_env_local "$WT_ROOT/tests/fixtures/dot.env.local" "$BATS_TEST_TMPDIR/.env.local" myprojekt-app-gel-123.docker.test myprojekt_app_gel_123 s3cret
  grep -qx 'APP_URL=https://myprojekt-app-gel-123.docker.test' "$BATS_TEST_TMPDIR/.env.local"
  grep -q 'mysql://myprojekt_app_gel_123:s3cret@infra_mysql_8_0/myprojekt_app_gel_123' "$BATS_TEST_TMPDIR/.env.local"
  grep -q 'serverVersion=8.0' "$BATS_TEST_TMPDIR/.env.local"  # query string preserved
}
