load work-helpers

setup() { setup_work; }

@test "feature tirée de develop à jour, main pullée, état actif au nom de la session" {
  make_project app
  remote_commit app main m1
  remote_commit app develop d1
  cd "$PROJECTS/app"

  run work start GEL-1 --slug export-pdf
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1-export-pdf ]
  [ -f d1 ]
  [ ! -f m1 ]
  [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]
  state_of app | jq -e '.state=="active" and .ticket=="GEL-1" and .branch=="feature/GEL-1-export-pdf"
    and .base=="develop" and .owner_session=="sess-me" and (.started_at|length)>0' >/dev/null
}

@test "hotfix tirée de main à jour" {
  make_project app
  remote_commit app main m1
  cd "$PROJECTS/app"

  run work start BUG-9 --hotfix
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = hotfix/BUG-9 ]
  [ -f m1 ]
  state_of app | jq -e '.base=="main"' >/dev/null
}

@test "sans develop, la feature est tirée de main" {
  make_project app nodevelop
  cd "$PROJECTS/app"

  run work start GEL-3
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-3 ]
  state_of app | jq -e '.base=="main"' >/dev/null
}

@test "démarre depuis une autre branche propre" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q develop

  run work start GEL-4
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-4 ]
}

@test "refus si un ticket est déjà actif" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1

  run work start GEL-2
  [ "$status" -ne 0 ]
  [[ "$output" == *"GEL-1"* ]]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-2
  [ "$status" -ne 0 ]
}

@test "refus sur arbre sale, rien n'est modifié" {
  make_project app
  cd "$PROJECTS/app"
  echo x > dirty.txt

  run work start GEL-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"arbre"* ]]
  [ "$(git branch --show-current)" = main ]
  [ ! -f .git/claude-work.json ]
}

@test "refus si la branche existe déjà en local ou sur origin" {
  make_project app
  cd "$PROJECTS/app"
  git branch -q feature/GEL-1 develop

  run work start GEL-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"existe"* ]]

  git branch -q -D feature/GEL-1
  git push -q origin develop:refs/heads/feature/GEL-1
  run work start GEL-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"existe"* ]]
  [ "$(git branch --show-current)" = main ]
  [ "$(jq -r .state .git/claude-work.json 2>/dev/null || echo free)" = free ]
}

@test "refus d'un nom invalide ou absent" {
  make_project app
  cd "$PROJECTS/app"

  run work start 'GEL 1'
  [ "$status" -ne 0 ]
  run work start GEL-1 --slug 'a/b'
  [ "$status" -ne 0 ]
  run work start
  [ "$status" -ne 0 ]
  [ ! -f .git/claude-work.json ]
}

@test "avertit s'il reste des PR en attente" {
  make_project app
  cd "$PROJECTS/app"
  echo '{"state":"free","pending_prs":[{"ticket":"GEL-0","branch":"feature/GEL-0","base":"develop","number":3,"url":"u","parked":false}]}' > .git/claude-work.json
  gh_set feature/GEL-0 OPEN 3

  run work start GEL-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR en attente"*"GEL-0"* ]]
  state_of app | jq -e '.state=="active" and (.pending_prs|length)==1' >/dev/null
}

@test "ménage : PR mergée nettoyée, PR ouverte et branche mise de côté conservées" {
  make_project app
  cd "$PROJECTS/app"
  git branch -q feature/GEL-A develop
  git branch -q feature/GEL-B develop
  git branch -q feature/GEL-C develop
  gh_set feature/GEL-A MERGED 1
  gh_set feature/GEL-B OPEN 2
  jq -n '{state:"free",pending_prs:[
    {ticket:"GEL-A",branch:"feature/GEL-A",base:"develop",number:1,url:"u1",parked:false},
    {ticket:"GEL-B",branch:"feature/GEL-B",base:"develop",number:2,url:"u2",parked:false},
    {ticket:"GEL-C",branch:"feature/GEL-C",base:"develop",number:null,url:null,parked:true}]}' > .git/claude-work.json

  run work start GEL-1
  [ "$status" -eq 0 ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-A
  [ "$status" -ne 0 ]
  git show-ref --verify --quiet refs/heads/feature/GEL-B
  git show-ref --verify --quiet refs/heads/feature/GEL-C
  state_of app | jq -e '(.pending_prs|map(.ticket))==["GEL-B","GEL-C"]' >/dev/null
}

@test "deux start simultanés : un seul réussit" {
  make_project app
  cd "$PROJECTS/app"

  ( work start GEL-1 >/dev/null 2>&1; echo $? > "$BATS_TEST_TMPDIR/r1" ) &
  ( work start GEL-2 >/dev/null 2>&1; echo $? > "$BATS_TEST_TMPDIR/r2" ) &
  wait
  [ "$(cat "$BATS_TEST_TMPDIR/r1" "$BATS_TEST_TMPDIR/r2" | grep -cx 0)" -eq 1 ]
  state_of app | jq -e '.state=="active"' >/dev/null
}
