load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/db.sh"
  export WT_DRY_RUN=1
  printf 'MYSQL_ROOT_PASSWORD=rootpw\n' > "$WT_ROOT/.env.test"; export WT_ENV_FILE="$WT_ROOT/.env.test"
}
teardown() { rm -f "$WT_ROOT/.env.test"; }

@test "create emits CREATE DATABASE/USER/GRANT on the default MySQL container" {
  run wt_db_create app_x s3cret
  [[ "$output" == *"docker exec infra_mysql_8_0 mysql -uroot"* ]]
  [[ "$output" == *"CREATE DATABASE IF NOT EXISTS \`app_x\`"* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'app_x'"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`app_x\`.*"* ]]
}
@test "drop emits DROP DATABASE/USER" {
  run wt_db_drop app_x
  [[ "$output" == *"DROP DATABASE IF EXISTS \`app_x\`"* ]]
  [[ "$output" == *"DROP USER IF EXISTS 'app_x'"* ]]
}
@test "mariadb container uses the mariadb client (not the absent mysql binary)" {
  WT_DB_CONTAINER=infra_mariadb_11_3
  run wt_db_create app_x s3cret
  [[ "$output" == *"docker exec infra_mariadb_11_3 mariadb -uroot"* ]]
  [[ "$output" != *"infra_mariadb_11_3 mysql"* ]]
}
@test "resolve container reads the DATABASE_URL host from .env.local" {
  printf 'DATABASE_URL="mysql://u:p@infra_mysql_8_0/db?serverVersion=8.0"\n' > "$BATS_TEST_TMPDIR/mysql.env"
  WT_DB_CONTAINER=placeholder
  wt_db_resolve_container "$BATS_TEST_TMPDIR/mysql.env"
  [ "$WT_DB_CONTAINER" = infra_mysql_8_0 ]

  printf 'DATABASE_URL="mysql://u:p@infra_mariadb_11_3/db?serverVersion=mariadb-11.3.2"\n' > "$BATS_TEST_TMPDIR/maria.env"
  wt_db_resolve_container "$BATS_TEST_TMPDIR/maria.env"
  [ "$WT_DB_CONTAINER" = infra_mariadb_11_3 ]
}
@test "resolve container tolerates a host:port and keeps value when URL/file missing" {
  printf 'DATABASE_URL="mysql://root:pw@infra_mysql_8_0:3306/db"\n' > "$BATS_TEST_TMPDIR/port.env"
  WT_DB_CONTAINER=placeholder
  wt_db_resolve_container "$BATS_TEST_TMPDIR/port.env"
  [ "$WT_DB_CONTAINER" = infra_mysql_8_0 ]

  WT_DB_CONTAINER=infra_mysql_8_0
  wt_db_resolve_container "/nonexistent/.env.local"
  [ "$WT_DB_CONTAINER" = infra_mysql_8_0 ]
}
