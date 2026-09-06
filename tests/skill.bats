load helpers

setup() { setup_wt; SK="$WT_ROOT/skills/worktree-env/SKILL.md"; }

@test "skill file exists with name+description frontmatter" {
  [ -f "$SK" ]
  head -6 "$SK" | grep -q '^name:'
  head -6 "$SK" | grep -q '^description:'
  grep -q 'wt create' "$SK"
  grep -q 'wt destroy' "$SK"
}
