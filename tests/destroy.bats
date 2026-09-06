load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"; source "$WT_ROOT/lib/naming.sh"
  export WT_DRY_RUN=1 WT_YES=1
  wt_reg_add '{"project":"myprojekt-app-gel-123","app":"myprojekt-app","slug":"gel-123","path":"'"$HOME"'/wt/myprojekt-app-gel-123","branch":"feature/gel-123","db":"myprojekt_app_gel_123","domain":"myprojekt-app-gel-123.docker.test"}'
  mkdir -p "$HOME/wt/myprojekt-app-gel-123"
}
@test "destroy emits down -> drop db -> worktree remove and clears registry" {
  run wt destroy myprojekt-app gel-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"down -v"* ]]
  [[ "$output" == *"DROP DATABASE IF EXISTS \`myprojekt_app_gel_123\`"* ]]
}
@test "destroy refuses unknown env" {
  run wt destroy myprojekt-app nope; [ "$status" -ne 0 ]; [[ "$output" == *"not managed"* ]]
}

@test "destroy refuses a path outside the managed \$HOME/wt dir" {
  local slug; slug="$(wt_slugify unmanaged-1)"
  local project="myprojekt-app-$slug"
  wt_reg_add '{"project":"'"$project"'","app":"myprojekt-app","slug":"'"$slug"'","path":"'"$HOME"'/elsewhere/'"$slug"'","branch":"feature/'"$slug"'","db":"myprojekt_app_'"${slug//-/_}"'","domain":"'"$project"'.docker.test"}'
  run wt destroy myprojekt-app unmanaged-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not under"* ]]
  [[ "$output" != *"down -v"* ]]
  [[ "$output" != *"DROP DATABASE"* ]]
}

@test "destroy refuses a dirty worktree unless --force" {
  local slug; slug="$(wt_slugify dirty-1)"
  local project="myprojekt-app-$slug"
  local path="$HOME/wt/$project"
  mkdir -p "$path"
  ( cd "$path"
    git init -q
    git config user.email t@t; git config user.name t
    echo hi > a.txt; git add a.txt; git commit -qm init
    echo change >> a.txt )
  wt_reg_add '{"project":"'"$project"'","app":"myprojekt-app","slug":"'"$slug"'","path":"'"$path"'","branch":"feature/'"$slug"'","db":"myprojekt_app_'"${slug//-/_}"'","domain":"'"$project"'.docker.test"}'

  run wt destroy myprojekt-app dirty-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]

  run wt destroy myprojekt-app dirty-1 --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"down -v"* ]]
  [[ "$output" == *"DROP DATABASE IF EXISTS \`myprojekt_app_${slug//-/_}\`"* ]]
}
