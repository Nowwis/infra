# shellcheck shell=bash
for m in ui naming registry; do source "$WT_ROOT/lib/$m.sh"; done
cmd_open() {
  local app="$1" slug; slug="$(wt_slugify "$2")"
  local project; project="$(wt_project "$app" "$slug")"
  wt_reg_exists "$project" || die "env not found: $project"
  wt_reg_get "$project" | jq -r .path
}
