load helpers
setup() {
  setup_wt
  export WT_SETTINGS="$BATS_TEST_TMPDIR/settings.json"
  export WT_SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
  echo '{}' > "$WT_SETTINGS"
}
@test "install adds a SessionStart command hook idempotently" {
  run "$WT_ROOT/bin/wt-hook-install"; [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart[0].hooks[0].type == "command"' "$WT_SETTINGS" >/dev/null
  jq -e '.hooks.SessionStart[0].hooks[0].command | test("wt-session-hook")' "$WT_SETTINGS" >/dev/null
  before="$(jq -S . "$WT_SETTINGS")"
  "$WT_ROOT/bin/wt-hook-install"   # second run
  [ "$(jq -S . "$WT_SETTINGS")" = "$before" ]   # no duplicate
  [ -L "$WT_SKILLS_DIR/worktree-env" ] || [ -e "$WT_SKILLS_DIR/worktree-env" ]
}
@test "uninstall removes the hook entry" {
  "$WT_ROOT/bin/wt-hook-install"
  run "$WT_ROOT/bin/wt-hook-install" --uninstall; [ "$status" -eq 0 ]
  jq -e '(.hooks.SessionStart // []) | map(.hooks[].command | test("wt-session-hook")) | any | not' "$WT_SETTINGS" >/dev/null
}
