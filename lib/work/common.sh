# shellcheck shell=bash
# lib/work/common.sh — configuration des projets, identité de session, état sous verrou,
# synchro des bases (docs/2026-09-15-work-console-design.md §4.1-4.3).
: "${WORK_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
: "${WORK_CONF:=$WORK_ROOT/etc/work/projects.conf}"
: "${WORK_SESSIONS_DIR:=$HOME/.claude/sessions}"

work_die()  { printf 'work : %s\n' "$*" >&2; exit 1; }
work_say()  { printf '%s\n' "$*"; }
work_warn() { printf '! %s\n' "$*" >&2; }
work_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Projet contenant <path> (plus long préfixe de repo) → WP_NAME WP_REPO WP_MAIN WP_DEVELOP WP_FORGE.
work_project_for_path() {
  local target="${1%/}" name repo main develop forge best=-1
  WP_NAME="" WP_REPO="" WP_MAIN="" WP_DEVELOP="" WP_FORGE=""
  [ -f "$WORK_CONF" ] || return 1
  while IFS='|' read -r name repo main develop forge; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    case "$target/" in
      "$repo"/*)
        if [ "${#repo}" -gt "$best" ]; then
          best=${#repo}
          WP_NAME="$name" WP_REPO="$repo" WP_MAIN="$main" WP_DEVELOP="$develop" WP_FORGE="$forge"
        fi
        ;;
    esac
  done < "$WORK_CONF"
  [ -n "$WP_NAME" ] || return 1
  export WP_NAME WP_REPO WP_MAIN WP_DEVELOP WP_FORGE
}

# Identité de la session appelante : celle de Claude Code, sinon l'utilisateur Unix.
work_session_id() { printf '%s' "${CLAUDE_CODE_SESSION_ID:-human:$(id -un)}"; }

# 0 si la session est vivante. Une identité humaine l'est toujours.
work_session_alive() {
  local id="$1" f pid
  case "$id" in human:*) return 0 ;; "") return 1 ;; esac
  while IFS= read -r f; do
    [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$id" ] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  done < <(grep -lsF -- "$id" "$WORK_SESSIONS_DIR"/*.json 2>/dev/null)
  return 1
}

work_state_file() {
  local gcd
  gcd="$(git -C "$WP_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  printf '%s/claude-work.json' "$gcd"
}

work_state_get() {
  local f; f="$(work_state_file)" || return 1
  if [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
    jq '.pending_prs //= []' "$f"
  else
    printf '{"state":"free","pending_prs":[]}\n'
  fi
}

work_state_put() {
  local f tmp; f="$(work_state_file)" || return 1
  tmp="$f.tmp.$$"
  printf '%s' "$1" | jq '.' > "$tmp" && mv "$tmp" "$f"
}

# Exécute "$@" sous verrou exclusif du projet (sous-shell : work_die n'interrompt que la commande).
work_locked() {
  local lock; lock="$(dirname "$(work_state_file)")/claude-work.lock"
  (
    flock -w 10 9 || work_die "projet $WP_NAME occupé (verrou claude-work.lock)"
    "$@"
  ) 9>"$lock"
}

work_current_branch() { git -C "$WP_REPO" branch --show-current 2>/dev/null; }
work_is_clean()       { [ -z "$(git -C "$WP_REPO" status --porcelain 2>/dev/null)" ]; }
work_dirty_count()    { git -C "$WP_REPO" status --porcelain 2>/dev/null | grep -c .; }

work_check_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || work_die "nom invalide : '$1' (autorisé : lettres, chiffres, . _ -)"
}

# fetch puis avance rapide de main et develop : pull pour la branche checkoutée, fetch b:b pour l'autre.
work_sync_bases() {
  local cur b
  git -C "$WP_REPO" fetch -q origin || work_die "fetch origin impossible ($WP_NAME)"
  cur="$(work_current_branch)"
  for b in "$WP_MAIN" "$WP_DEVELOP"; do
    [ -n "$b" ] || continue
    git -C "$WP_REPO" show-ref --verify --quiet "refs/remotes/origin/$b" || continue
    if [ "$b" = "$cur" ]; then
      git -C "$WP_REPO" pull -q --ff-only origin "$b" \
        || work_die "$b ne peut pas avancer en avance rapide sur origin/$b (divergence)"
    else
      git -C "$WP_REPO" fetch -q origin "$b:$b" \
        || work_die "$b ne peut pas avancer en avance rapide sur origin/$b (divergence)"
    fi
  done
}

# État GitHub de la PR d'une branche (OPEN, MERGED, CLOSED) ; vide si aucune.
work_pr_state() {
  ( cd "$WP_REPO" && gh pr view "$1" --json state --jq .state 2>/dev/null ) || true
}
