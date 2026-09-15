load helpers

setup() {
  setup_wt
  export WT_DECOM_ROOT="$BATS_TEST_TMPDIR/Project"
  export WT_DECOM_SESSIONS_DIR="$HOME/.claude/sessions"
  export WT_SETTINGS="$HOME/.claude/settings.json"
  export WT_SKILLS_DIR="$HOME/.claude/skills"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  mkdir -p "$WT_DECOM_ROOT" "$WT_DECOM_SESSIONS_DIR" "$WT_SKILLS_DIR" "$HOME/wt"
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  # wt destroy simulé : journalise l'appel, retire le worktree et l'entrée de registre
  cat > "$STUBS/wt" <<'EOF'
#!/usr/bin/env bash
echo "wt $*" >> "$CALLS"
if [ "$1" = destroy ]; then
  p="$HOME/wt/$2-$3"
  r="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir)"
  git -C "${r%/.git}" worktree remove --force "$p"
  jq --arg p "$2-$3" 'map(select(.project != $p))' "$WT_STATE/registry.json" > "$WT_STATE/r.tmp" \
    && mv "$WT_STATE/r.tmp" "$WT_STATE/registry.json"
fi
EOF
  cat > "$STUBS/wt-hook-install" <<'EOF'
#!/usr/bin/env bash
echo "hook-install $*" >> "$CALLS"
EOF
  chmod +x "$STUBS/wt" "$STUBS/wt-hook-install"
  export WT_DECOM_WT_BIN="$STUBS/wt" WT_DECOM_HOOK_INSTALL="$STUBS/wt-hook-install"
  D="$WT_ROOT/bin/wt-decommission"
}

# make_repo <org/name> : checkout principal avec un remote nu et main poussée
make_repo() {
  local repo="$WT_DECOM_ROOT/$1" remote="$BATS_TEST_TMPDIR/remotes/$1.git"
  mkdir -p "$(dirname "$repo")" "$(dirname "$remote")"
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  git -C "$repo" remote add origin "$remote"
  echo base > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm init
  git -C "$repo" push -q -u origin main
}

# add_wt <org/name> <chemin> <branche> : worktree secondaire, branche poussée
add_wt() {
  git -C "$WT_DECOM_ROOT/$1" worktree add -q -b "$3" "$2" main
  git -C "$2" push -q -u origin "$3"
}

@test "dry-run classe SAUF, À RISQUE et MANQUANT sans rien modifier" {
  make_repo Org/app
  add_wt Org/app "$HOME/wt/app-clean" feature/clean
  add_wt Org/app "$HOME/wt/app-dirty" feature/dirty
  echo x > "$HOME/wt/app-dirty/new.txt"
  add_wt Org/app "$BATS_TEST_TMPDIR/gone" feature/gone
  rm -rf "$BATS_TEST_TMPDIR/gone"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  SAUF +.*/wt/app-clean '
  echo "$output" | grep -qE '^  À RISQUE +.*/wt/app-dirty .*1 fichier'
  echo "$output" | grep -qE '^  MANQUANT +.*/gone '
  echo "$output" | grep -q 'BLOQUANT : 1'
  echo "$output" | grep -q 'Simulation'
  [ -d "$HOME/wt/app-clean" ] && [ -d "$HOME/wt/app-dirty" ]
  [ ! -s "$CALLS" ]
}

@test "un commit jamais poussé rend le worktree À RISQUE" {
  make_repo Org/app
  add_wt Org/app "$HOME/wt/app-ahead" feature/ahead
  echo y > "$HOME/wt/app-ahead/f"
  git -C "$HOME/wt/app-ahead" add f
  git -C "$HOME/wt/app-ahead" commit -qm local

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  À RISQUE +.*/wt/app-ahead .*1 commit'
}

@test "un worktree où tourne une session Claude vivante est EN USAGE ; une session morte est ignorée" {
  make_repo Org/app
  local bridge="$WT_DECOM_ROOT/Org/app/.claude/worktrees/bridge-x"
  add_wt Org/app "$bridge" hotfix/x
  add_wt Org/app "$HOME/wt/app-dead" feature/dead
  jq -n --argjson pid "$$" --arg cwd "$bridge" '{pid:$pid,cwd:$cwd}' > "$WT_DECOM_SESSIONS_DIR/live.json"
  jq -n --arg cwd "$HOME/wt/app-dead" '{pid:2147483646,cwd:$cwd}' > "$WT_DECOM_SESSIONS_DIR/dead.json"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  EN USAGE +.*bridge-x '
  echo "$output" | grep -qE '^  SAUF +.*/wt/app-dead '
}

@test "un dossier sous ~/wt qui n'est pas un worktree est INCONNU et bloquant" {
  mkdir -p "$HOME/wt/stray"; touch "$HOME/wt/stray/f"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  INCONNU +.*/wt/stray'
  echo "$output" | grep -q 'BLOQUANT : 1'
}

@test "l'inventaire signale registre, .worktreeinclude et configuration Claude" {
  make_repo Org/app
  mkdir -p "$WT_STATE"
  jq -n '[{project:"myapp-t1",app:"myapp",slug:"t1",path:"/x"}]' > "$WT_STATE/registry.json"
  printf '.mcp.json\n' > "$WT_DECOM_ROOT/Org/app/.worktreeinclude"
  echo '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/x/bin/wt-session-hook"}]}]}}' > "$WT_SETTINGS"
  ln -s /nonexistent "$WT_SKILLS_DIR/worktree-env"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'myapp-t1'
  echo "$output" | grep -qE 'à supprimer +.*Org/app/.worktreeinclude'
  echo "$output" | grep -q 'hook SessionStart wt-session-hook : présent'
  echo "$output" | grep -q 'skill worktree-env : présent'
}

@test "option inconnue refusée" {
  run "$D" --bogus
  [ "$status" -ne 0 ]
}
