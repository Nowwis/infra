load helpers
setup() {
  setup_wt
  source "$WT_ROOT/lib/profile.sh"
  wt_profile_load "$WT_ROOT/tests/fixtures/apps.conf"
  # Workaround: Define a compatible run() that works with bats
  run() {
    local _status=0 _output
    _output=$("$@" 2>&1) || _status=$?
    status=$_status
    output=$_output
  }
}

@test "get returns a field" {
  [ "$(wt_profile_get myprojekt-app type)" = "symfony" ]
  [ "$(wt_profile_get myprojekt-app base)" = "develop" ]
}
@test "require accepts a symfony app" {
  run wt_profile_require myprojekt-app
  [ "$status" -eq 0 ]
}
@test "require rejects unknown app" {
  run wt_profile_require nope
  [ "$status" -ne 0 ]; [[ "$output" == *"unknown app"* ]]
}
@test "require rejects non-symfony in v1" {
  run wt_profile_require legacy-thing
  [ "$status" -ne 0 ]; [[ "$output" == *"not supported"* ]]
}
