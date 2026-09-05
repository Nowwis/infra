load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/gitwt.sh"
  REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$REPO"; ( cd "$REPO"
    git init -q -b main; git config user.email t@t; git config user.name t
    echo hi > a.txt; git add a.txt; git commit -qm init
    git branch develop )
}
@test "add worktree on develop then dirty detection" {
  local p="$BATS_TEST_TMPDIR/wt1"
  wt_git_add_worktree "$REPO" develop feature/x "$p"
  [ -f "$p/a.txt" ]
  [ "$(git -C "$p" branch --show-current)" = "feature/x" ]
  run wt_git_is_dirty "$p"; [ "$status" -ne 0 ]     # clean
  echo change >> "$p/a.txt"
  run wt_git_is_dirty "$p"; [ "$status" -eq 0 ]      # dirty
}
@test "remove worktree" {
  local p="$BATS_TEST_TMPDIR/wt2"
  wt_git_add_worktree "$REPO" develop feature/y "$p"
  wt_git_remove_worktree "$REPO" "$p"
  [ ! -d "$p" ]
}
