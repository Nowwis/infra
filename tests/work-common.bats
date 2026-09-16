load work-helpers

setup() {
  setup_work
  source "$WORK_ROOT/lib/work/common.sh"
}

@test "résolution par plus long préfixe, sans confondre un préfixe de nom" {
  make_project app
  printf 'sub|%s|main|develop|github\n' "$PROJECTS/app/packages/sub" >> "$WORK_CONF"
  mkdir -p "$PROJECTS/app/packages/sub/x"

  work_project_for_path "$PROJECTS/app/src/file.php"
  [ "$WP_NAME" = app ]
  [ "$WP_REPO" = "$PROJECTS/app" ]
  [ "$WP_MAIN" = main ]
  [ "$WP_DEVELOP" = develop ]
  [ "$WP_FORGE" = github ]

  work_project_for_path "$PROJECTS/app/packages/sub/x"
  [ "$WP_NAME" = sub ]

  run work_project_for_path "$PROJECTS/application"
  [ "$status" -ne 0 ]
  run work_project_for_path /elsewhere
  [ "$status" -ne 0 ]
}

@test "état par défaut, puis écriture et relecture hors de l'arbre git" {
  make_project app
  work_project_for_path "$PROJECTS/app"

  [ "$(work_state_get | jq -r .state)" = free ]
  [ "$(work_state_get | jq -c .pending_prs)" = "[]" ]

  work_state_put '{"state":"active","ticket":"GEL-1","pending_prs":[]}'
  [ "$(work_state_get | jq -r .ticket)" = GEL-1 ]
  [ "$(work_state_file)" = "$PROJECTS/app/.git/claude-work.json" ]
  [ -z "$(git -C "$PROJECTS/app" status --porcelain)" ]
}

@test "sessions : vivante, morte, inconnue, humaine ; identité courante" {
  live_session s-live
  dead_session s-dead

  work_session_alive s-live
  run work_session_alive s-dead
  [ "$status" -ne 0 ]
  run work_session_alive s-unknown
  [ "$status" -ne 0 ]
  work_session_alive human:simon

  [ "$(work_session_id)" = sess-me ]
  [ "$(CLAUDE_CODE_SESSION_ID='' work_session_id)" = "human:$(id -un)" ]
}

@test "sync_bases avance main (checkoutée) et develop (non checkoutée)" {
  make_project app
  remote_commit app main m1
  remote_commit app develop d1
  work_project_for_path "$PROJECTS/app"

  work_sync_bases
  [ -f "$PROJECTS/app/m1" ]
  [ "$(git -C "$PROJECTS/app" rev-parse develop)" = "$(git -C "$PROJECTS/app" rev-parse origin/develop)" ]
}

@test "sync_bases échoue si develop a divergé" {
  make_project app
  remote_commit app develop d1
  git -C "$PROJECTS/app" checkout -q develop
  echo l > "$PROJECTS/app/l"
  git -C "$PROJECTS/app" add l
  git -C "$PROJECTS/app" commit -qm local
  git -C "$PROJECTS/app" checkout -q main
  work_project_for_path "$PROJECTS/app"

  run work_sync_bases
  [ "$status" -ne 0 ]
  [[ "$output" == *develop* ]]
}

@test "work status --json : projet libre et propre" {
  make_project app
  cd "$PROJECTS/app"

  run work status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name=="app" and .state=="free" and .dirty==0 and .current_branch=="main" and (.drift|length)==0' >/dev/null
}

@test "work status : un fichier non suivi n'est pas une dérive, un fichier suivi modifié oui" {
  make_project app
  cd "$PROJECTS/app"
  echo nouveau > untracked.txt

  run work status --json
  echo "$output" | jq -e '.dirty == 0 and .untracked == 1 and .drift == []' >/dev/null

  echo modifié >> README
  run work status --json
  echo "$output" | jq -e '.dirty == 1 and .drift == ["hors-workflow"]' >/dev/null

  git checkout -q -- README
  rm untracked.txt
  git checkout -q develop
  run work status --json
  echo "$output" | jq -e '.current_branch == "develop" and .drift == ["hors-workflow"]' >/dev/null
}

@test "work status : verrou tenu par une session morte" {
  make_project app
  dead_session s-dead
  work_project_for_path "$PROJECTS/app"
  work_state_put '{"state":"active","ticket":"GEL-1","branch":"main","base":"develop","owner_session":"s-dead","started_at":"x","pending_prs":[]}'
  cd "$PROJECTS/app"

  run work status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state=="active" and .owner=="s-dead" and .owner_alive==false and .is_me==false and (.drift|index("verrou-orphelin"))!=null' >/dev/null
}

@test "work status --all --json liste tous les projets, et le texte les nomme" {
  make_project app
  make_project api nodevelop
  cd "$BATS_TEST_TMPDIR"

  run work status --all --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length==2 and (map(.name)|sort)==["api","app"]' >/dev/null

  run work status --all
  [ "$status" -eq 0 ]
  [[ "$output" == *app* ]]
  [[ "$output" == *api* ]]
}

@test "work status hors projet échoue avec un message clair" {
  cd "$BATS_TEST_TMPDIR"
  run work status
  [ "$status" -ne 0 ]
  [[ "$output" == *"hors projet"* ]]
}
