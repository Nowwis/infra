# shellcheck shell=bash
# lib/cmd_destroy.sh — DESTROY orchestrator for the wt CLI.
source "${WT_ROOT}/lib/ui.sh"
source "${WT_ROOT}/lib/naming.sh"
source "${WT_ROOT}/lib/profile.sh"
source "${WT_ROOT}/lib/registry.sh"
source "${WT_ROOT}/lib/gitwt.sh"
source "${WT_ROOT}/lib/db.sh"
source "${WT_ROOT}/lib/docker.sh"

cmd_destroy() {
  local app="" slug_src="" force=0 prune=0
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes)          WT_YES=1 ;;
      --force)        force=1 ;;
      --prune-branch) prune=1 ;;
      --dry-run)      WT_DRY_RUN=1 ;;   # normally stripped by bin/wt; tolerate here
      --*)            die "unknown flag: $1" ;;
      *)              pos+=("$1") ;;
    esac
    shift
  done

  app="${pos[0]:-}"
  slug_src="${pos[1]:-}"
  [ -n "$app" ] && [ -n "$slug_src" ] \
    || die "usage: wt destroy <app> <slug> [--yes] [--force] [--prune-branch]"

  local slug project
  slug="$(wt_slugify "$slug_src")"
  project="$(wt_project "$app" "$slug")"

  wt_reg_exists "$project" || die "env not managed by wt: $project"

  local e path db branch reg_compose reg_db_container
  e="$(wt_reg_get "$project")"
  path="$(jq -r '.path // empty' <<<"$e")"
  db="$(jq -r '.db // empty' <<<"$e")"
  branch="$(jq -r '.branch // empty' <<<"$e")"
  reg_compose="$(jq -r '.compose // empty' <<<"$e")"
  reg_db_container="$(jq -r '.db_container // empty' <<<"$e")"

  # Profile lookup is best-effort: tolerate a missing/unset WT_APPS_FILE
  # entirely (do not fall back to a machine-local default apps.conf), so
  # destroy never depends on a profile being configured.
  if [ -n "${WT_APPS_FILE:-}" ] && [ -f "$WT_APPS_FILE" ]; then
    wt_profile_load "$WT_APPS_FILE" 2>/dev/null || true
  fi
  local repo compose
  repo="$(wt_profile_get "$app" repo 2>/dev/null || true)"
  compose="${reg_compose:-$(wt_profile_get "$app" compose 2>/dev/null || true)}"
  compose="${compose:-.docker/docker-compose.yml}"

  # SAFETY: never operate on anything outside $HOME/wt/ (never a main checkout).
  case "$path" in
    "$HOME"/wt/*) : ;;
    *) die "refusing to destroy: path '$path' is not under \$HOME/wt" ;;
  esac

  # SAFETY: refuse a worktree with uncommitted changes unless --force.
  if [ -d "$path" ] && wt_git_is_dirty "$path" && [ "$force" != 1 ]; then
    die "worktree has uncommitted changes: $path (use --force to destroy anyway)"
  fi

  # SAFETY: refuse a worktree with unpushed commits unless --force.
  local unpushed=0
  if [ -d "$path" ]; then
    unpushed="$(wt_git_unpushed "$path")"
    [ -n "$unpushed" ] || unpushed=0
    if [ "$unpushed" -gt 0 ] && [ "$force" != 1 ]; then
      die "worktree has $unpushed unpushed commit(s); use --force"
    fi
  fi

  log "plan: destroy '$project'"
  log "plan: docker compose -p $project -f $compose down -v"
  log "plan: DROP DATABASE IF EXISTS \`$db\`"
  log "plan: remove worktree $path (unpushed=$unpushed)"
  if [ "$prune" = 1 ] && [ -n "$branch" ]; then
    log "plan: delete branch $branch"
  fi
  if [ "$WT_DRY_RUN" = "1" ]; then
    log "plan: remove '$project' from registry"
  fi

  confirm "destroy '$project' ?" || die "aborted"

  wt_docker_down "$path" "$compose" "$project"

  # Cible le bon conteneur DB pour le DROP : valeur enregistrée à la création,
  # sinon dérivée du .env.local du worktree, sinon défaut de db.sh. Évite de
  # DROP sur le mauvais moteur (mysql vs mariadb).
  if [ -n "$reg_db_container" ]; then
    WT_DB_CONTAINER="$reg_db_container"
  else
    wt_db_resolve_container "$path/.env.local"
  fi
  wt_db_drop "$db"

  if [ -n "$repo" ]; then
    wt_git_remove_worktree "$repo" "$path"
  else
    wt_run git worktree remove --force "$path"
  fi

  if [ "$prune" = 1 ] && [ -n "$repo" ] && [ -n "$branch" ]; then
    wt_run git -C "$repo" branch -d "$branch"
  fi

  # Ruling D: guarded — no direct registry mutation while WT_DRY_RUN=1.
  if [ "$WT_DRY_RUN" != "1" ]; then
    wt_reg_remove "$project"
  fi

  ok "destroyed $project"
}
