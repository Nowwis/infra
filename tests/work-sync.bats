load work-helpers

setup() {
  setup_work
  BODY="$BATS_TEST_TMPDIR/body.md"; echo "Corps" > "$BODY"
}

commit_work() { echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; }

@test "sync met main et develop à jour sans toucher à la branche courante" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b feature/en-cours develop
  remote_commit app main m1
  remote_commit app develop d1

  run work sync
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/en-cours ]
  [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]
  [ "$(git rev-parse develop)" = "$(git rev-parse origin/develop)" ]
  [[ "$output" == *main* ]]
  [[ "$output" == *develop* ]]
}

@test "sync depuis main met à jour la branche checkoutée" {
  make_project app
  cd "$PROJECTS/app"
  remote_commit app main m1

  run work sync
  [ "$status" -eq 0 ]
  [ -f m1 ]
  [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]
}

@test "sync sans develop configuré ne traite que main" {
  make_project app nodevelop
  cd "$PROJECTS/app"
  remote_commit app main m1

  run work sync
  [ "$status" -eq 0 ]
  [ -f m1 ]
  [[ "$output" != *develop* ]]
}

@test "sync refuse si un fichier suivi est modifié sur la base courante" {
  make_project app
  cd "$PROJECTS/app"
  echo modifié >> README

  run work sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"suivis"* ]]
  [ -n "$(git status --porcelain --untracked-files=no)" ]
}

@test "sync laisse intact un ticket en cours" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  remote_commit app develop d1

  run work sync
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  [ "$(git rev-parse develop)" = "$(git rev-parse origin/develop)" ]
  state_of app | jq -e '.state == "active" and .ticket == "GEL-1"' >/dev/null
}

@test "sync --tidy revient sur main et supprime une branche dont la PR est mergée" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b feature/GEL-9 develop
  commit_work a.txt
  git push -q -u origin feature/GEL-9
  gh_set feature/GEL-9 MERGED 9
  remote_commit app main m1

  run work sync --tidy
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-9
  [ "$status" -ne 0 ]
  [ -f "$PROJECTS/app/m1" ]
}

@test "sync --tidy garde une branche dont la PR n'est pas mergée" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b feature/GEL-8 develop
  commit_work a.txt
  gh_set feature/GEL-8 OPEN 8

  run work sync --tidy
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-8 ]
  [[ "$output" == *"GEL-8"* ]]
}

@test "sync --tidy ne touche pas à une branche qui porte un ticket actif" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  gh_set feature/GEL-1 MERGED 1

  run work sync --tidy
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  state_of app | jq -e '.state == "active"' >/dev/null
}

@test "sync hors projet échoue clairement" {
  cd "$BATS_TEST_TMPDIR"
  run work sync
  [ "$status" -ne 0 ]
  [[ "$output" == *"hors projet"* ]]
}

@test "sync tolère des fichiers non suivis sur une base" {
  make_project app
  cd "$PROJECTS/app"
  echo x > untracked.txt
  remote_commit app main m1

  run work sync
  [ "$status" -eq 0 ]
  [ -f m1 ]
  [ -f untracked.txt ]
}

@test "sync --tidy range une branche mergée malgré des fichiers non suivis" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b feature/GEL-7 develop
  commit_work a.txt
  git push -q -u origin feature/GEL-7
  gh_set feature/GEL-7 MERGED 7
  echo x > untracked.txt

  run work sync --tidy
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  [ -f untracked.txt ]
}

@test "sync ignore une base disparue d'origin (référence obsolète élaguée)" {
  make_project app
  cd "$PROJECTS/app"
  git push -q origin --delete develop
  remote_commit app main m1

  run work sync
  [ "$status" -eq 0 ]
  [ -f m1 ]
  [[ "$output" == *main* ]]
}
