# shellcheck shell=bash
# lib/cmd_create.sh — CREATE orchestrator for the wt CLI.
source "${WT_ROOT}/lib/ui.sh"
source "${WT_ROOT}/lib/naming.sh"
source "${WT_ROOT}/lib/profile.sh"
source "${WT_ROOT}/lib/registry.sh"
source "${WT_ROOT}/lib/envgen.sh"
source "${WT_ROOT}/lib/gitwt.sh"
source "${WT_ROOT}/lib/db.sh"
source "${WT_ROOT}/lib/docker.sh"

cmd_create() {
  local app="" slug_src="" mode="feature" ticket="" keep_on_error=0
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature)        mode="feature" ;;
      --hotfix)         mode="hotfix" ;;
      --ticket)         ticket="${2:-}"; shift ;;
      --keep-on-error)  keep_on_error=1 ;;
      --dry-run)        WT_DRY_RUN=1 ;;   # normally stripped by bin/wt; tolerate here
      --*)              die "unknown flag: $1" ;;
      *)                pos+=("$1") ;;
    esac
    shift
  done

  app="${pos[0]:-}"
  slug_src="${pos[1]:-}"
  [ -n "$app" ] || die "usage: wt create <app> <slug> [--feature|--hotfix] [--ticket KEY]"
  if [ -n "$ticket" ]; then slug_src="$ticket"; fi
  [ -n "$slug_src" ] || die "missing slug (provide a positional slug or --ticket KEY)"

  # --- resolve profile ---
  wt_profile_load "${WT_APPS_FILE:-$WT_ROOT/etc/wt/apps.conf}"
  wt_profile_require "$app"
  local repo compose install profile_base
  repo="$(wt_profile_get "$app" repo)"
  compose="$(wt_profile_get "$app" compose)"
  install="$(wt_profile_get "$app" install)"
  profile_base="$(wt_profile_get "$app" base)"

  # --- compute names ---
  local slug project domain db path branch base
  slug="$(wt_slugify "$slug_src")"
  project="$(wt_project "$app" "$slug")"
  domain="$(wt_domain "$app" "$slug")"
  db="$(wt_db "$app" "$slug")"
  path="$(wt_path "$app" "$slug")"
  if [ "$mode" = "hotfix" ]; then
    branch="$(wt_branch hotfix "$slug")"; base="main"
  else
    branch="$(wt_branch feature "$slug")"; base="$profile_base"
  fi

  # --- preflight ---
  # Gate on the registry file already existing so a dry-run (or a first-ever
  # create) does not create it as a side effect (Ruling D). If it doesn't
  # exist yet, no env can be registered, so the check trivially passes.
  if [ -f "$WT_STATE/registry.json" ] && wt_reg_exists "$project"; then
    die "env already exists: $project"
  fi

  # --- rollback bookkeeping ---
  local did_worktree=0 did_db=0 did_up=0
  _wt_create_rollback() {
    set +e
    trap - ERR
    if [ "$keep_on_error" = "1" ]; then
      warn "keep-on-error: leaving partial env '$project' in place"
      return 0
    fi
    warn "rolling back '$project'"
    [ "$did_up" = "1" ]       && wt_docker_down "$path" "$compose" "$project"
    [ "$did_db" = "1" ]       && wt_db_drop "$db"
    [ "$did_worktree" = "1" ] && wt_git_remove_worktree "$repo" "$path"
    return 0
  }
  trap '_wt_create_rollback' ERR

  local pass; pass="$(openssl rand -hex 12)"

  log "create '$project'  branch=$branch base=$base"

  # --- git: fetch + worktree ---
  wt_run git -C "$repo" fetch origin
  wt_git_add_worktree "$repo" "$base" "$branch" "$path"
  did_worktree=1

  # --- runtime files (Ruling D: guarded, no fs writes in dry-run) ---
  # Untracked runtime files (.env.local, .env.test.local, .mcp.json) are NOT
  # brought in by `git worktree add`, so copy them from the repo into the
  # worktree before generating/patching the env files.
  if [ "$WT_DRY_RUN" != "1" ]; then
    mkdir -p "$path/.docker"
    local f
    for f in .env.local .env.test.local .mcp.json; do
      [ -f "$repo/$f" ] && cp "$repo/$f" "$path/$f"
    done
    wt_gen_docker_env "$repo/.docker/.env" "$path/.docker/.env" "$project" "$domain"
    wt_patch_env_local "$repo/.env.local" "$path/.env.local" "$domain" "$db" "$pass"
  else
    log "plan: copy runtime files (.env.local, .env.test.local, .mcp.json)"
    log "plan: write $path/.docker/.env  (project=$project domain=$domain)"
    log "plan: patch $path/.env.local     (db=$db, generated password)"
  fi

  # --- database ---
  wt_db_create "$db" "$pass"
  did_db=1

  # --- docker up ---
  wt_docker_up "$path" "$compose" "$project"
  did_up=1

  # --- install ---
  if [ -n "$install" ]; then
    ( [ -d "$path" ] && cd "$path"; wt_run $install )
  fi

  # --- register (Ruling D: guarded, no registry write in dry-run) ---
  if [ "$WT_DRY_RUN" != "1" ]; then
    wt_reg_add "$(jq -nc \
      --arg project "$project" --arg app "$app" --arg slug "$slug" \
      --arg domain "$domain" --arg db "$db" --arg path "$path" \
      --arg branch "$branch" --arg base "$base" --arg compose "$compose" \
      '{project:$project,app:$app,slug:$slug,domain:$domain,db:$db,path:$path,branch:$branch,base:$base,compose:$compose}')"
  else
    log "plan: register env '$project' in registry"
  fi

  trap - ERR
  ok "ready: https://$domain  ($path)"
}
