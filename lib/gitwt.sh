# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
wt_git_add_worktree() { # repo base branch path
  local repo="$1" base="$2" branch="$3" path="$4"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    wt_run git -C "$repo" worktree add "$path" "$branch"
  else
    wt_run git -C "$repo" worktree add -b "$branch" "$path" "$base"
  fi
}
wt_git_remove_worktree() { # repo path
  wt_run git -C "$1" worktree remove --force "$2"
}
# Depot proprietaire d'un worktree, derive du worktree lui-meme.
# --git-common-dir pointe le .git du checkout principal, y compris depuis un
# worktree lie. Aucune dependance a un profil : c'est la source de verite locale.
wt_git_owner_repo() { # path -> prints repo path, or nothing
  local gcd
  gcd="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gcd" ] || return 1
  printf '%s' "${gcd%/.git}"
}
wt_git_is_dirty() { # path -> 0 if dirty
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}
wt_git_unpushed() { # path -> prints count of commits not on any upstream
  git -C "$1" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0
}
