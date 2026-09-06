# shellcheck shell=bash
# tests/smoke.bats — whole-CLI dry-run smoke check against the REAL
# etc/wt/apps.conf profile (no WT_APPS_FILE / WT_ENV_FILE overrides).
#
# This exercises the actual v1 app profile (parisrental) end-to-end in
# WT_DRY_RUN mode: the only real command that touches the outside world is a
# read-only `git show-ref` against the real repo (to decide whether the
# branch already exists); every mutating step (git worktree add, DB create,
# docker compose up, install) is wt_run-gated and only printed as a plan
# line. No filesystem, database, docker, or registry mutation occurs.
load helpers
setup() {
  setup_wt
  export WT_DRY_RUN=1
}

@test "create dry-run against real profile emits domain + install" {
  run wt create parisrental TICKET-1 --feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"parisrental-ticket-1.docker.test"* ]]
  [[ "$output" == *"make install"* ]]
}
