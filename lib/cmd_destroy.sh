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

  local e path db branch reg_compose reg_db_container reg_repo
  e="$(wt_reg_get "$project")"
  path="$(jq -r '.path // empty' <<<"$e")"
  db="$(jq -r '.db // empty' <<<"$e")"
  branch="$(jq -r '.branch // empty' <<<"$e")"
  reg_compose="$(jq -r '.compose // empty' <<<"$e")"
  reg_db_container="$(jq -r '.db_container // empty' <<<"$e")"
  reg_repo="$(jq -r '.repo // empty' <<<"$e")"

  # Profile lookup is best-effort: tolerate a missing/unset WT_APPS_FILE
  # entirely (do not fall back to a machine-local default apps.conf), so
  # destroy never depends on a profile being configured.
  if [ -n "${WT_APPS_FILE:-}" ] && [ -f "$WT_APPS_FILE" ]; then
    wt_profile_load "$WT_APPS_FILE" 2>/dev/null || true
  fi
  # Depot proprietaire, par ordre de fiabilite decroissante :
  #   1. celui memorise au create ;
  #   2. celui derive du worktree lui-meme (--git-common-dir), toujours exact ;
  #   3. celui du profil, si un apps.conf a ete fourni.
  # Sans ces deux premiers recours, `repo` restait vide des que WT_APPS_FILE
  # n'etait pas defini, et le `git worktree remove` de repli s'executait dans le
  # REPERTOIRE COURANT, donc sur un autre depot : « is not a working tree ».
  local repo compose
  repo="${reg_repo:-}"
  if [ -z "$repo" ] && [ -d "$path" ]; then
    repo="$(wt_git_owner_repo "$path" 2>/dev/null || true)"
  fi
  [ -n "$repo" ] || repo="$(wt_profile_get "$app" repo 2>/dev/null || true)"
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

  # La suppression doit aller jusqu'au bout : chaque etape est best-effort et on
  # signale ce qui reste. Avant, `set -e` interrompait des la premiere erreur et
  # laissait une entree de registre fantome pointant vers un environnement a
  # moitie detruit, impossible a rejouer.
  local leftovers=0
  wt_docker_down "$path" "$compose" "$project" || { warn "conteneurs/volumes : echec"; leftovers=1; }

  # Cible le bon conteneur DB pour le DROP : valeur enregistrée à la création,
  # sinon dérivée du .env.local du worktree, sinon défaut de db.sh. Évite de
  # DROP sur le mauvais moteur (mysql vs mariadb).
  if [ -n "$reg_db_container" ]; then
    WT_DB_CONTAINER="$reg_db_container"
  else
    wt_db_resolve_container "$path/.env.local"
  fi
  wt_db_drop "$db" || { warn "DROP DATABASE $db : echec"; leftovers=1; }

  if [ -n "$repo" ]; then
    if ! wt_git_remove_worktree "$repo" "$path"; then
      warn "worktree non retire : $path"
      # Cause la plus frequente : un conteneur tournant en root a depose des
      # fichiers dans le worktree via un bind mount (historiquement les logs
      # nginx). Sans ce diagnostic, l'utilisateur ne voit qu'un « Permission
      # denied » sans savoir quoi corriger.
      local foreign
      foreign="$(find "$path" ! -user "$(id -un)" -printf '%u %p\n' 2>/dev/null | head -5)"
      if [ -n "$foreign" ]; then
        warn "fichiers appartenant a un autre utilisateur (extrait) :"
        printf '    %s\n' "$foreign" >&2
        warn "corriger avec : sudo chown -R $(id -un): $path  puis relancer destroy"
      fi
      leftovers=1
    fi
  else
    warn "depot proprietaire introuvable, worktree laisse en place : $path"; leftovers=1
  fi

  if [ "$prune" = 1 ] && [ -n "$repo" ] && [ -n "$branch" ]; then
    wt_run git -C "$repo" branch -d "$branch" || warn "branche $branch non supprimee"
  fi

  # Ruling D: guarded — no direct registry mutation while WT_DRY_RUN=1.
  if [ "$WT_DRY_RUN" != "1" ]; then
    wt_reg_remove "$project"
  fi

  if [ "$leftovers" = 1 ]; then
    warn "destroyed $project, avec des residus signales ci-dessus (voir: wt doctor)"
  else
    ok "destroyed $project"
  fi
}
