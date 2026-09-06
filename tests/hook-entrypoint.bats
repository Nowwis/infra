load helpers
setup() {
  setup_wt
  HOOK="$WT_ROOT/bin/wt-session-hook"
  # fake managed repo on a feature branch (wip)
  REPO="$BATS_TEST_TMPDIR/repos/myapp"; mkdir -p "$REPO"; ( cd "$REPO"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init; git checkout -q -b feature/x )
  export WT_HOOK_APPS="$BATS_TEST_TMPDIR/apps.conf"
  printf 'myapp|%s|symfony|develop|.docker/docker-compose.yml|make install\n' "$REPO" > "$WT_HOOK_APPS"
  # stub `wt` on PATH returning an empty env list
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; printf '#!/bin/bash\necho "[]"\n' > "$BIN/wt"; chmod +x "$BIN/wt"
  export WT_HOOK_WT="$BIN/wt"
}
@test "emits additionalContext for a wip managed repo" {
  run bash -c 'printf "{\"cwd\":\"%s\"}" "'"$REPO"'" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("feature/x")' >/dev/null
}
@test "silent (no additionalContext) for an unmanaged cwd" {
  run bash -c 'printf "{\"cwd\":\"/tmp/nope-%s\"}" "$$" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
  # either empty stdout or JSON without additionalContext
  if [ -n "$output" ]; then echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") == ""' >/dev/null; fi
}
@test "never fails even if wt/git blow up (fail-safe exit 0)" {
  export WT_HOOK_WT="/definitely/not/a/binary"
  run bash -c 'printf "{\"cwd\":\"%s\"}" "'"$REPO"'" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
}
