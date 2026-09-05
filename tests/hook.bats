load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/hook.sh"
  CONF="$BATS_TEST_TMPDIR/apps.conf"
  printf 'myapp|%s|symfony|develop|.docker/docker-compose.yml|make install\n' "$BATS_TEST_TMPDIR/repos/myapp" > "$CONF"
  mkdir -p "$BATS_TEST_TMPDIR/repos/myapp/sub"
}
@test "app_for_cwd matches a managed repo (and subdir)" {
  run wt_hook_app_for_cwd "$BATS_TEST_TMPDIR/repos/myapp/sub" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == myapp$'\t'* ]]
  [[ "$output" == *$'\t'develop ]]
}
@test "app_for_cwd rejects an unmanaged dir" {
  run wt_hook_app_for_cwd "/tmp/somewhere-else" "$CONF"
  [ "$status" -ne 0 ]
}
@test "is_wip true when branch != base" {
  local r="$BATS_TEST_TMPDIR/gitrepo"; mkdir -p "$r"; ( cd "$r"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init; git checkout -q -b feature/x )
  run wt_hook_is_wip "$r" develop; [ "$status" -eq 0 ]
}
@test "is_wip false when clean on base" {
  local r="$BATS_TEST_TMPDIR/gitrepo2"; mkdir -p "$r"; ( cd "$r"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init )
  run wt_hook_is_wip "$r" develop; [ "$status" -ne 0 ]
}
@test "build_context empty when no wip and no envs" {
  run wt_hook_build_context myapp "" 0 ""
  [ -z "$output" ]
}
@test "build_context mentions app, branch, count when wip" {
  run wt_hook_build_context myapp feature/x 3 ""
  [[ "$output" == *"myapp"* ]]; [[ "$output" == *"feature/x"* ]]; [[ "$output" == *"3"* ]]
}
@test "build_context includes envs even without wip branch" {
  run wt_hook_build_context myapp "" 0 "myapp-TICKET1, myapp-TICKET2"
  [ -n "$output" ]
  [[ "$output" == *"myapp-TICKET1"* ]]
}
