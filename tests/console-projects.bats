load work-helpers

setup() {
  setup_work
  export CONSOLE_STATE="$BATS_TEST_TMPDIR/state"
  C="$INFRA_ROOT/bin/console-collector"
  BODY="$BATS_TEST_TMPDIR/body.md"; echo "Corps" > "$BODY"
}

commit_work() { echo "$1" > "$1"; git add "$1"; git commit -qm "$1"; }

@test "projects : reprend l'état de work et ajoute l'état GitHub des PR" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  commit_work feat.txt
  work pr --title t --body-file "$BODY" >/dev/null
  gh_set feature/GEL-1 MERGED 7
  "$C" once prs >/dev/null

  run "$C" once projects
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 10 and (.data | length) == 1
    and .data[0].name == "app" and .data[0].state == "free"
    and (.data[0].pending_prs | length) == 1
    and .data[0].pending_prs[0].ticket == "GEL-1"
    and .data[0].pending_prs[0].gh_state == "MERGED"' >/dev/null
}

@test "projects : sans section prs, l'état GitHub est simplement absent" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  commit_work feat.txt
  work pr --title t --body-file "$BODY" >/dev/null

  run "$C" once projects
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data[0].pending_prs[0].gh_state == null' >/dev/null
}

@test "projects : ticket actif et dérive remontés" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-2 >/dev/null
  echo modifié >> README

  run "$C" once projects
  echo "$output" | jq -e '.data[0].state == "active" and .data[0].ticket == "GEL-2"
    and .data[0].dirty == 1 and .data[0].is_me == true' >/dev/null
}

@test "prs : une branche mise de côté n'est pas interrogée" {
  make_project app
  cd "$PROJECTS/app"
  work start GEL-1 >/dev/null
  echo wip > wip.txt
  work park >/dev/null
  : > "$GH_CALLS"

  run "$C" once prs
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == {}' >/dev/null
  run grep -c 'pr view' "$GH_CALLS"
  [ "$output" = 0 ]
}

@test "prs : un projet GitLab n'est pas interrogé avec gh" {
  make_project glab gitlab
  cd "$PROJECTS/glab"
  jq -n '{state:"free",pending_prs:[{ticket:"X-1",branch:"feature/X-1",base:"develop",number:null,url:null,parked:false}]}' \
    > .git/claude-work.json
  : > "$GH_CALLS"

  run "$C" once prs
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == {}' >/dev/null
  [ ! -s "$GH_CALLS" ]
}

@test "prs : état remonté par projet et par branche" {
  make_project app
  cd "$PROJECTS/app"
  jq -n '{state:"free",pending_prs:[
    {ticket:"A-1",branch:"feature/A-1",base:"develop",number:1,url:"u1",parked:false},
    {ticket:"A-2",branch:"feature/A-2",base:"develop",number:2,url:"u2",parked:false}]}' \
    > .git/claude-work.json
  gh_set feature/A-1 OPEN 1
  gh_set feature/A-2 MERGED 2

  run "$C" once prs
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cadence == 300 and .data.app["feature/A-1"] == "OPEN"
    and .data.app["feature/A-2"] == "MERGED"' >/dev/null
}

@test "projects : aucun projet configuré" {
  : > "$WORK_CONF"
  cd "$BATS_TEST_TMPDIR"
  run "$C" once projects
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data == []' >/dev/null
}
