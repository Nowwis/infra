setup_infra() {
  export INFRA_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PATH="$INFRA_ROOT/bin:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}
