source "$BATS_TEST_DIRNAME/helpers.bash"

setup_work() {
  setup_infra
  export WORK_ROOT="$INFRA_ROOT"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  printf '[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "$GIT_CONFIG_GLOBAL"
  export WORK_CONF="$BATS_TEST_TMPDIR/projects.conf"; : > "$WORK_CONF"
  export WORK_SESSIONS_DIR="$HOME/.claude/sessions"; mkdir -p "$WORK_SESSIONS_DIR"
  export CLAUDE_CODE_SESSION_ID=sess-me
  export PROJECTS="$BATS_TEST_TMPDIR/Project"; mkdir -p "$PROJECTS"
  export GH_DIR="$BATS_TEST_TMPDIR/gh"; mkdir -p "$GH_DIR"
  export GH_CALLS="$GH_DIR/calls"; : > "$GH_CALLS"
  local stubs="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$stubs"
  # gh simulé : l'état de chaque PR vit dans $GH_DIR/<branche avec / → _>.{state,number,url}
  cat > "$stubs/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_CALLS"
key() { printf '%s' "$1" | tr '/' '_'; }
if [ "$1" = pr ] && [ "$2" = view ]; then
  f="$GH_DIR/$(key "$3")"
  [ -f "$f.state" ] || { echo "no pull requests found for branch \"$3\"" >&2; exit 1; }
  case "$*" in
    *"--json state "*) cat "$f.state" ;;
    *) printf '%s\t%s\n' "$(cat "$f.number")" "$(cat "$f.url")" ;;
  esac
elif [ "$1" = pr ] && [ "$2" = create ]; then
  h=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && h="$2"; shift; done
  f="$GH_DIR/$(key "$h")"
  echo OPEN > "$f.state"; echo 7 > "$f.number"; echo "https://github.com/o/r/pull/7" > "$f.url"
  cat "$f.url"
fi
EOF
  chmod +x "$stubs/gh"
  export PATH="$WORK_ROOT/bin:$stubs:$PATH"
}

# gh_set <branche> <STATE> [numéro] : état d'une PR simulée
gh_set() {
  local f; f="$GH_DIR/$(printf '%s' "$1" | tr '/' '_')"
  echo "$2" > "$f.state"; echo "${3:-7}" > "$f.number"; echo "https://github.com/o/r/pull/${3:-7}" > "$f.url"
}

# make_project <nom> [nodevelop] [gitlab] : checkout avec remote nu, main (+develop) poussés, ligne de conf
make_project() {
  local name="$1" develop=develop forge=github a
  for a in "${@:2}"; do
    case "$a" in nodevelop) develop="" ;; gitlab) forge=gitlab ;; esac
  done
  local repo="$PROJECTS/$name" remote="$BATS_TEST_TMPDIR/remotes/$name.git"
  mkdir -p "$(dirname "$remote")"
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  git -C "$repo" remote add origin "$remote"
  echo base > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm init
  git -C "$repo" push -q -u origin main
  if [ -n "$develop" ]; then
    git -C "$repo" branch -q develop
    git -C "$repo" push -q -u origin develop
  fi
  printf '%s|%s|main|%s|%s\n' "$name" "$repo" "$develop" "$forge" >> "$WORK_CONF"
}

# remote_commit <nom> <branche> <fichier> : commit poussé sur origin depuis un autre clone
remote_commit() {
  local tmp="$BATS_TEST_TMPDIR/other-$1-$RANDOM"
  git clone -q "$BATS_TEST_TMPDIR/remotes/$1.git" "$tmp"
  git -C "$tmp" checkout -q "$2"
  echo "$3" > "$tmp/$3"
  git -C "$tmp" add "$3"
  git -C "$tmp" commit -qm "$3"
  git -C "$tmp" push -q origin "$2"
}

# live_session / dead_session <id> : fichier de session Claude (pid vivant = shell bats)
live_session() { jq -n --arg id "$1" --argjson pid "$$" '{sessionId:$id,pid:$pid}' > "$WORK_SESSIONS_DIR/$1.json"; }
dead_session() { jq -n --arg id "$1" '{sessionId:$id,pid:2147483646}' > "$WORK_SESSIONS_DIR/$1.json"; }

# state_of <nom> : contenu de claude-work.json du projet
state_of() { cat "$PROJECTS/$1/.git/claude-work.json"; }
