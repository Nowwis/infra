load work-helpers

setup() { setup_work; F="$WORK_ROOT/skills/work/SKILL.md"; }

@test "skill work : frontmatter valide" {
  [ -f "$F" ]
  [ "$(head -n1 "$F")" = "---" ]
  grep -q '^name: work$' "$F"
  grep -q '^description: ' "$F"
}

@test "skill work : couvre chaque commande et les validations avant action sortante" {
  local c
  for c in "work start" "work pr" "work merged" "work resume" "work park" "work status" "work adopt" "work takeover"; do
    grep -qF "$c" "$F"
  done
  grep -qi 'validation' "$F"
  grep -qi 'mention' "$F"
}
