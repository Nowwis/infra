load work-helpers

setup() {
  setup_work
  BODY="$BATS_TEST_TMPDIR/body.md"; echo "Corps" > "$BODY"
}

commit_work() { echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; }

@test "park commite le travail en cours, pousse, revient sur main, entrée mise de côté" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  echo wip > wip.txt

  run work park
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  git ls-remote --exit-code --heads origin feature/GEL-1 >/dev/null
  [ "$(git log -1 --format=%s feature/GEL-1)" = "wip: GEL-1 parked" ]
  state_of app | jq -e '.state=="free" and (.pending_prs|length)==1 and .pending_prs[0].ticket=="GEL-1"
    and .pending_prs[0].parked==true and .pending_prs[0].number==null and .pending_prs[0].base=="develop"' >/dev/null
}

@test "park sans changement ne crée pas de commit" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt

  run work park
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%s feature/GEL-1)" = feat.txt ]
}

@test "park refusé pour une autre session" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1

  CLAUDE_CODE_SESSION_ID=other run work park
  [ "$status" -ne 0 ]
  [[ "$output" == *"autre session"* ]]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
}

@test "resume reprend une branche mise de côté" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  echo wip > wip.txt
  work park

  run work resume GEL-1
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  [ -f wip.txt ]
  state_of app | jq -e '.state=="active" and .ticket=="GEL-1" and .branch=="feature/GEL-1" and .base=="develop"
    and .owner_session=="sess-me" and .pending_prs==[]' >/dev/null
}

@test "resume récupère les commits poussés sur la branche depuis la PR" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work a.txt
  work pr --title t --body-file "$BODY"
  remote_commit app feature/GEL-1 review.txt

  run work resume GEL-1
  [ "$status" -eq 0 ]
  [ -f review.txt ]
}

@test "resume recrée la branche locale depuis origin si elle a disparu" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work a.txt
  work pr --title t --body-file "$BODY"
  git branch -q -D feature/GEL-1

  run work resume GEL-1
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  [ -f a.txt ]
}

@test "resume refusé si un ticket est actif ou si le ticket n'est pas en attente" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work a.txt
  work pr --title t --body-file "$BODY"
  work start GEL-2

  run work resume GEL-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"GEL-2"* ]]

  make_project other
  cd "$PROJECTS/other"
  run work resume NOPE
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas en attente"* ]]
}

@test "adopt enregistre la branche courante comme ticket, sans toucher à git" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b feature/legacy develop
  echo wip > wip.txt

  run work adopt LEG-1
  [ "$status" -eq 0 ]
  [ -f wip.txt ]
  state_of app | jq -e '.state=="active" and .ticket=="LEG-1" and .branch=="feature/legacy" and .base=="develop"
    and .owner_session=="sess-me"' >/dev/null
}

@test "adopt : base main pour une branche hotfix ; refus sur main, develop, ou ticket actif" {
  make_project app
  cd "$PROJECTS/app"
  git checkout -q -b hotfix/urgent main
  run work adopt H-1
  [ "$status" -eq 0 ]
  state_of app | jq -e '.base=="main"' >/dev/null
  run work adopt H-2
  [ "$status" -ne 0 ]

  make_project other
  cd "$PROJECTS/other"
  run work adopt X-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"main"* ]]
  git checkout -q develop
  run work adopt X-1
  [ "$status" -ne 0 ]
}

@test "takeover réattribue un ticket et signale l'état de l'ancienne session" {
  make_project app
  cd "$PROJECTS/app"
  dead_session s-old
  CLAUDE_CODE_SESSION_ID=s-old work start GEL-1

  run work takeover
  [ "$status" -eq 0 ]
  [[ "$output" == *"s-old"*"terminée"* ]]
  state_of app | jq -e '.owner_session=="sess-me" and .ticket=="GEL-1"' >/dev/null

  make_project other
  cd "$PROJECTS/other"
  live_session s-live
  CLAUDE_CODE_SESSION_ID=s-live work start GEL-2
  run work takeover
  [ "$status" -eq 0 ]
  [[ "$output" == *"s-live"*"encore active"* ]]
  state_of other | jq -e '.owner_session=="sess-me"' >/dev/null
}

@test "takeover sans ticket actif échoue" {
  make_project app
  cd "$PROJECTS/app"
  run work takeover
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucun ticket actif"* ]]
}
