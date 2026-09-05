setup_wt() {
  WT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PATH="$WT_ROOT/bin:$PATH"
  export WT_STATE="$BATS_TEST_TMPDIR/state"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}
