load work-helpers

setup() { setup_work; }

commit_work() { echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; }

@test "abort d'un ticket sans travail : branche supprimée, projet libre" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null

  run work abort
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-1
  [ "$status" -ne 0 ]
  state_of app | jq -e '.state == "free" and (has("ticket") | not)' >/dev/null
}

@test "abort refuse s'il y a des commits, et renvoie vers park" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  commit_work a.txt

  run work abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"park"* ]]
  [[ "$output" == *"1 commit"* ]]
  git show-ref --verify --quiet refs/heads/feature/GEL-1
  state_of app | jq -e '.state == "active"' >/dev/null
}

@test "abort refuse s'il y a des fichiers suivis modifiés" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  echo modifié >> README

  run work abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"fichier"* ]]
  state_of app | jq -e '.state == "active"' >/dev/null
  grep -q modifié README
}

@test "abort --force supprime malgré le travail et annonce ce qui est perdu" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  commit_work a.txt
  echo modifié >> README

  run work abort --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 commit"* ]]
  [ "$(git branch --show-current)" = main ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-1
  [ "$status" -ne 0 ]
  state_of app | jq -e '.state == "free"' >/dev/null
  run grep -q modifié README
  [ "$status" -ne 0 ]
}

@test "abort d'un ticket tenu par une autre session est refusé" {
  make_project app
  cd "$PROJECTS/app"
  live_session s-other
  CLAUDE_CODE_SESSION_ID=s-other work start GEL-1 >/dev/null

  run work abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"takeover"* ]]
  state_of app | jq -e '.state == "active" and .owner_session == "s-other"' >/dev/null
}

@test "abort nettoie l'état même si la branche a déjà disparu" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  git checkout -q main
  git branch -q -D feature/GEL-1

  run work abort
  [ "$status" -eq 0 ]
  state_of app | jq -e '.state == "free"' >/dev/null
}

@test "abort --force conserve la branche distante et le dit" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  commit_work a.txt
  git push -q -u origin feature/GEL-1

  run work abort --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin"* ]]
  git ls-remote --exit-code --heads origin feature/GEL-1 >/dev/null
  state_of app | jq -e '.state == "free"' >/dev/null
}

@test "abort sans ticket actif, et hors projet" {
  make_project app
  cd "$PROJECTS/app"
  run work abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun ticket actif"* ]]

  cd "$BATS_TEST_TMPDIR"
  run work abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"hors projet"* ]]
}

@test "les PR en attente survivent à un abort" {
  make_project app
  cd "$PROJECTS/app"
  echo corps > "$BATS_TEST_TMPDIR/body.md"
  work start GEL-1 >/dev/null
  commit_work a.txt
  work pr --title t --body-file "$BATS_TEST_TMPDIR/body.md" >/dev/null
  work start GEL-2 >/dev/null

  run work abort
  [ "$status" -eq 0 ]
  state_of app | jq -e '.state == "free" and (.pending_prs | map(.ticket)) == ["GEL-1"]' >/dev/null
}
