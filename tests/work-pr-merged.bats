load work-helpers

setup() {
  setup_work
  BODY="$BATS_TEST_TMPDIR/body.md"; echo "Corps de PR" > "$BODY"
}

# commit_on_branch : un commit de travail dans le projet courant
commit_work() { echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; }

# gitlab_url <nom> : origin en https GitLab, redirigé vers le remote local
gitlab_url() {
  git -C "$PROJECTS/$1" config "url.$BATS_TEST_TMPDIR/remotes/.insteadOf" "https://gitlab.example.com/grp/"
  git -C "$PROJECTS/$1" remote set-url origin "https://gitlab.example.com/grp/$1.git"
}

@test "pr pousse, crée la PR vers develop, revient sur main à jour, ticket en attente" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt
  remote_commit app main m1

  run work pr --title "feat: GEL-1" --body-file "$BODY"
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = main ]
  [ -f m1 ]
  git ls-remote --exit-code --heads origin feature/GEL-1 >/dev/null
  grep -qF "gh pr create --base develop --head feature/GEL-1 --title feat: GEL-1 --body-file $BODY" "$GH_CALLS"
  state_of app | jq -e '.state=="free" and (has("owner_session")|not) and (.pending_prs|length)==1
    and .pending_prs[0].ticket=="GEL-1" and .pending_prs[0].branch=="feature/GEL-1" and .pending_prs[0].base=="develop"
    and .pending_prs[0].number==7 and .pending_prs[0].url=="https://github.com/o/r/pull/7" and .pending_prs[0].parked==false' >/dev/null
}

@test "hotfix : la PR cible main" {
  make_project app
  cd "$PROJECTS/app"
  work start BUG-1 --hotfix
  commit_work fix.txt

  run work pr --title "fix" --body-file "$BODY"
  [ "$status" -eq 0 ]
  grep -qF "gh pr create --base main --head hotfix/BUG-1" "$GH_CALLS"
}

@test "pr réutilise une PR déjà ouverte sans en créer" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt
  gh_set feature/GEL-1 OPEN 12

  run work pr
  [ "$status" -eq 0 ]
  run grep -c 'pr create' "$GH_CALLS"
  [ "$output" = 0 ]
  state_of app | jq -e '.pending_prs[0].number==12' >/dev/null
}

@test "sans PR existante, titre et corps sont exigés avant tout push" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt

  run work pr
  [ "$status" -ne 0 ]
  [[ "$output" == *"--title"* ]]
  run git ls-remote --exit-code --heads origin feature/GEL-1
  [ "$status" -ne 0 ]
  [ "$(git branch --show-current)" = feature/GEL-1 ]
  state_of app | jq -e '.state=="active"' >/dev/null
}

@test "pr refusée : autre session, arbre sale, mauvaise branche" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt

  CLAUDE_CODE_SESSION_ID=other run work pr --title t --body-file "$BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"autre session"* ]]

  echo x > dirty.txt
  run work pr --title t --body-file "$BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"arbre"* ]]
  rm dirty.txt

  git checkout -q develop
  run work pr --title t --body-file "$BODY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branche"* ]]
  [ ! -s "$GH_CALLS" ]
}

@test "GitLab : affiche l'URL de création de MR, sans appel gh" {
  make_project app gitlab
  gitlab_url app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt

  run work pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://gitlab.example.com/grp/app/-/merge_requests/new?merge_request[source_branch]=feature/GEL-1&merge_request[target_branch]=develop"* ]]
  [ ! -s "$GH_CALLS" ]
  [ "$(git branch --show-current)" = main ]
  state_of app | jq -e '.state=="free" and .pending_prs[0].ticket=="GEL-1" and .pending_prs[0].number==null' >/dev/null
}

@test "merged : bases synchronisées, branche supprimée, entrée retirée" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt
  work pr --title t --body-file "$BODY"
  gh_set feature/GEL-1 MERGED 7
  remote_commit app develop merged-code

  run work merged
  [ "$status" -eq 0 ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-1
  [ "$status" -ne 0 ]
  [ "$(git branch --show-current)" = main ]
  [ "$(git rev-parse develop)" = "$(git rev-parse origin/develop)" ]
  state_of app | jq -e '.pending_prs==[]' >/dev/null
}

@test "merged pendant un autre ticket actif : la branche courante ne change pas" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt
  work pr --title t --body-file "$BODY"
  work start GEL-2
  gh_set feature/GEL-1 MERGED 7

  run work merged GEL-1
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = feature/GEL-2 ]
  run git show-ref --verify --quiet refs/heads/feature/GEL-1
  [ "$status" -ne 0 ]
  state_of app | jq -e '.state=="active" and .ticket=="GEL-2" and .pending_prs==[]' >/dev/null
}

@test "merged refusé si la PR n'est pas mergée" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1
  commit_work feat.txt
  work pr --title t --body-file "$BODY"

  run work merged
  [ "$status" -ne 0 ]
  [[ "$output" == *"pas mergée"* ]]
  git show-ref --verify --quiet refs/heads/feature/GEL-1
  state_of app | jq -e '(.pending_prs|length)==1' >/dev/null
}

@test "merged exige KEY quand plusieurs PR sont en attente" {
  make_project app
  cd "$PROJECTS/app"
  jq -n '{state:"free",pending_prs:[
    {ticket:"GEL-A",branch:"feature/GEL-A",base:"develop",number:1,url:"u1",parked:false},
    {ticket:"GEL-B",branch:"feature/GEL-B",base:"develop",number:2,url:"u2",parked:false}]}' > .git/claude-work.json
  gh_set feature/GEL-A MERGED 1
  gh_set feature/GEL-B MERGED 2

  run work merged
  [ "$status" -ne 0 ]
  [[ "$output" == *"GEL-A"*"GEL-B"* ]]

  run work merged GEL-B
  [ "$status" -eq 0 ]
  state_of app | jq -e '(.pending_prs|map(.ticket))==["GEL-A"]' >/dev/null
}

@test "merged sur GitLab exige --confirmed" {
  make_project app gitlab
  cd "$PROJECTS/app"
  jq -n '{state:"free",pending_prs:[{ticket:"GEL-1",branch:"feature/GEL-1",base:"develop",number:null,url:null,parked:false}]}' > .git/claude-work.json

  run work merged
  [ "$status" -ne 0 ]
  [[ "$output" == *"--confirmed"* ]]

  run work merged --confirmed
  [ "$status" -eq 0 ]
  state_of app | jq -e '.pending_prs==[]' >/dev/null
  [ ! -s "$GH_CALLS" ]
}

@test "merged sans PR en attente échoue clairement" {
  make_project app
  cd "$PROJECTS/app"
  run work merged
  [ "$status" -ne 0 ]
  [[ "$output" == *"aucune PR"* ]]
}
