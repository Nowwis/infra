load helpers
setup() { setup_wt; }

@test "no args prints usage and fails" {
  run wt
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: wt"* ]]
}

@test "unknown subcommand fails" {
  run wt frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "wt_run wrapper prints plan in dry-run and does not execute" {
  run bash -c 'source "'"$WT_ROOT"'/lib/ui.sh"; WT_DRY_RUN=1; wt_run touch "'"$BATS_TEST_TMPDIR"'/should_not_exist"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ touch"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/should_not_exist" ]
}
