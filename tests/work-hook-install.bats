load work-helpers

setup() {
  setup_work
  I="$WORK_ROOT/bin/work-hook-install"
  export WORK_SETTINGS="$HOME/.claude/settings.json" WORK_SKILLS_DIR="$HOME/.claude/skills"
  mkdir -p "$HOME/.claude"
  cat > "$WORK_SETTINGS" <<'EOF'
{"permissions":{"allow":["Bash(git push:*)"]},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
   {"type":"command","command":"/home/u/.claude/hooks/guard-branch-clean.sh"},
   {"type":"command","command":"/home/u/.claude/hooks/prod-guard.sh"}]}]}}
EOF
  G="$WORK_ROOT/bin/work-guard"
  S="$WORK_ROOT/bin/work-session-hook"
}

@test "install : garde et SessionStart ajoutés, guard-branch-clean retiré, le reste préservé" {
  run "$I"
  [ "$status" -eq 0 ]
  jq -e --arg g "$G" --arg s "$S" '
    ([.hooks.PreToolUse[] | select(.matcher == "Edit|MultiEdit|Write|NotebookEdit|Bash") | .hooks[].command] | index($g)) != null
    and ([.hooks.SessionStart[].hooks[].command] | index($s)) != null
    and ([.hooks.PreToolUse[].hooks[].command] | map(test("guard-branch-clean")) | any | not)
    and ([.hooks.PreToolUse[].hooks[].command] | map(test("prod-guard")) | any)
    and .permissions.allow == ["Bash(git push:*)"]' "$WORK_SETTINGS" >/dev/null
  [ -L "$WORK_SKILLS_DIR/work" ]
  [ "$(readlink "$WORK_SKILLS_DIR/work")" = "$WORK_ROOT/skills/work" ]
  ls "$WORK_SETTINGS".bak-* >/dev/null
}

@test "install est idempotent" {
  "$I" >/dev/null
  "$I" >/dev/null
  jq -e --arg g "$G" --arg s "$S" '
    ([.hooks.PreToolUse[].hooks[].command] | map(select(. == $g)) | length) == 1
    and ([.hooks.SessionStart[].hooks[].command] | map(select(. == $s)) | length) == 1' "$WORK_SETTINGS" >/dev/null
}

@test "uninstall retire ses entrées et le lien, et garde prod-guard" {
  "$I" >/dev/null
  run "$I" --uninstall
  [ "$status" -eq 0 ]
  jq -e --arg g "$G" --arg s "$S" '
    ([.. | objects | select(has("command")) | .command] | (index($g) == null and index($s) == null))
    and ([.hooks.PreToolUse[].hooks[].command] | map(test("prod-guard")) | any)' "$WORK_SETTINGS" >/dev/null
  [ ! -e "$WORK_SKILLS_DIR/work" ]
}

@test "settings.json invalide : refus sans rien modifier" {
  echo 'pas du json' > "$WORK_SETTINGS"
  run "$I"
  [ "$status" -ne 0 ]
  [ "$(cat "$WORK_SETTINGS")" = 'pas du json' ]
}
