# shellcheck shell=bash
wt_slugify() {
  local s="$1"
  s="${s,,}"                       # lowercase
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-|-$//g')"
  printf '%s' "${s:0:40}" | sed -E 's/-$//'
}
wt_project() { printf '%s-%s' "$1" "$2"; }
wt_domain()  { printf '%s-%s.docker.test' "$1" "$2"; }
wt_db()      { printf '%s_%s' "$1" "$2" | tr '-' '_'; }
wt_path()    { printf '%s/wt/%s-%s' "$HOME" "$1" "$2"; }
wt_branch()  { printf '%s/%s' "$1" "$2"; }
