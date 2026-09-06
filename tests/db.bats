load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/db.sh"
  export WT_DRY_RUN=1
  printf 'MYSQL_ROOT_PASSWORD=rootpw\n' > "$WT_ROOT/.env.test"; export WT_ENV_FILE="$WT_ROOT/.env.test"
}
teardown() { rm -f "$WT_ROOT/.env.test"; }

@test "create emits CREATE DATABASE/USER/GRANT" {
  run wt_db_create app_x s3cret
  [[ "$output" == *"docker exec infra_mariadb_11_3"* ]]
  [[ "$output" == *"CREATE DATABASE IF NOT EXISTS \`app_x\`"* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'app_x'"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`app_x\`.*"* ]]
}
@test "drop emits DROP DATABASE/USER" {
  run wt_db_drop app_x
  [[ "$output" == *"DROP DATABASE IF EXISTS \`app_x\`"* ]]
  [[ "$output" == *"DROP USER IF EXISTS 'app_x'"* ]]
}
