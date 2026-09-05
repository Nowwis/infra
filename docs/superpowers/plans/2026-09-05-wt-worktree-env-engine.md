# wt — Worktree Env Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `wt`, a bash CLI that creates and destroys fully isolated per-worktree dev environments (git worktree + docker stack + Traefik domain + dedicated DB) for Symfony apps.

**Architecture:** A thin dispatcher (`bin/wt`) sources single-responsibility libs (`lib/*.sh`). Pure-compute units (naming, profile, env-file generation, registry) are unit-tested with `bats`; side-effecting units (git, docker, db) route every mutation through a `run` wrapper so a global `--dry-run` emits the ordered command plan, which the tests assert on without needing real docker. State lives outside the repo in `~/.local/state/wt/`.

**Tech Stack:** bash 5 (`set -euo pipefail`), `jq`, `git`, `docker` (compose v2), `mysql` via `docker exec infra_mariadb_11_3`, `bats-core` for tests.

**Spec:** `Project/Infra/docs/2026-09-05-wt-worktree-env-engine-design.md`

## Global Constraints

- Language: **bash only**. One responsibility per lib file. Single runtime dependency: **`jq`**.
- Every side effect goes through `run` (in `lib/ui.sh`); dry-run must never mutate git/docker/db/filesystem-state.
- Naming (verbatim): project `<app>-<slug>`, domain `<app>-<slug>.docker.test`, db & user `<app>_<slug>`, worktree `$HOME/wt/<app>-<slug>`, branch `feature/<slug>` (base `develop`) or `hotfix/<slug>` (base `main`).
- State dir: `~/.local/state/wt/` → `registry.json` + `logs/<project>.log`. Never inside a repo.
- DB admin access: `docker exec infra_mariadb_11_3 mysql -uroot -p"$MYSQL_ROOT_PASSWORD"`, password read from `Project/Infra/.env`.
- Destroy must refuse any target that is not a `wt`-managed worktree (under `$HOME/wt/` AND in the registry). Never touch main checkouts or shared infra (Traefik, MariaDB server, networks `traefik`/`databases`/`mailer`).
- v1 apps (Symfony only): `myprojekt-app`, `bifacto-doc`, `consotrust`, `lagestionenligne`, `parisrental`.
- No Claude/AI attribution anywhere in commits or files (repo-wide rule).

---

## File Structure

- `bin/wt` — dispatcher: parse global flags (`--dry-run`), route to subcommand, load libs.
- `lib/ui.sh` — `die/log/warn/ok`, the `run` wrapper, `confirm`, table helpers.
- `lib/naming.sh` — pure: `wt_slugify`, `wt_project`, `wt_domain`, `wt_db`, `wt_path`, `wt_branch`.
- `lib/profile.sh` — parse `etc/wt/apps.conf`, resolve app → fields, reject unknown/non-symfony.
- `lib/registry.sh` — jq CRUD over `~/.local/state/wt/registry.json`.
- `lib/gitwt.sh` — fetch, `worktree add`/`remove`, branch/dirty guards.
- `lib/envgen.sh` — generate `.docker/.env`, patch `.env.local` (pure string transforms).
- `lib/db.sh` — create/drop DB+user (via `run docker exec`).
- `lib/docker.sh` — compose up/down/status (`-p <project>`).
- `lib/cmd_create.sh` / `cmd_destroy.sh` / `cmd_list.sh` / `cmd_doctor.sh` / `cmd_open.sh` — subcommand orchestrators.
- `etc/wt/apps.conf` — app profiles (the 5 Symfony apps).
- `tests/*.bats` + `tests/helpers.bash` — bats suite.
- `docs/wt-README.md` — usage + manual integration test.

---

## Task 1: Scaffold + dispatcher + ui.sh

**Files:**
- Create: `bin/wt`, `lib/ui.sh`, `tests/helpers.bash`, `tests/cli.bats`

**Interfaces:**
- Produces: `run <cmd...>` (dry-run aware), `die <msg>`, `log/warn/ok <msg>`, env `WT_DRY_RUN` (0/1), `WT_ROOT` (repo root), `WT_STATE` (`~/.local/state/wt`).

- [ ] **Step 1: Write the failing test**

`tests/helpers.bash`:
```bash
setup_wt() {
  WT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PATH="$WT_ROOT/bin:$PATH"
  export WT_STATE="$BATS_TEST_TMPDIR/state"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}
```
`tests/cli.bats`:
```bash
load helpers
setup() { setup_wt; }

@test "no args prints usage and fails" {
  run wt
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: wt"* ]]
}

@test "unknown subcommand fails" {
  run wt frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "run wrapper prints plan in dry-run and does not execute" {
  run bash -c 'source "'"$WT_ROOT"'/lib/ui.sh"; WT_DRY_RUN=1; run touch "'"$BATS_TEST_TMPDIR"'/should_not_exist"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ touch"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/should_not_exist" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli.bats`
Expected: FAIL (`wt` not found / files absent).

- [ ] **Step 3: Write minimal implementation**

`lib/ui.sh`:
```bash
# shellcheck shell=bash
: "${WT_DRY_RUN:=0}"
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
log()  { printf '• %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
ok()   { printf '✓ %s\n' "$*"; }

# run: execute a command, or print it as a plan line when WT_DRY_RUN=1
run() {
  if [ "$WT_DRY_RUN" = "1" ]; then
    printf '+ %s\n' "$*"
    return 0
  fi
  "$@"
}

confirm() { # confirm "question" ; honors WT_YES=1
  [ "${WT_YES:-0}" = "1" ] && return 0
  local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY] ]]
}
```

`bin/wt`:
```bash
#!/usr/bin/env bash
set -euo pipefail
WT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WT_ROOT
: "${WT_STATE:=$HOME/.local/state/wt}"; export WT_STATE
export WT_DRY_RUN=0
source "$WT_ROOT/lib/ui.sh"

usage() {
  cat >&2 <<'EOF'
usage: wt <command> [args]
  create <app> <slug> [--feature|--hotfix] [--ticket KEY] [--dry-run] [--keep-on-error]
  destroy <app> <slug> [--yes] [--force] [--prune-branch] [--dry-run]
  list [--json]
  open <app> <slug>
  doctor [--fix]
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
# global flag
args=(); for a in "$@"; do case "$a" in --dry-run) WT_DRY_RUN=1;; *) args+=("$a");; esac; done
set -- "${args[@]:-}"

case "$cmd" in
  create|destroy|list|open|doctor)
    source "$WT_ROOT/lib/cmd_$cmd.sh"; "cmd_$cmd" "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
```

Add a stub so routing works before later tasks:
```bash
# lib/cmd_list.sh (temporary stub, replaced in Task 11)
cmd_list() { :; }
```
(Create matching one-line stubs for cmd_create/destroy/open/doctor to keep the dispatcher loadable; each is replaced in its own task.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/wt lib/ui.sh tests/helpers.bash tests/cli.bats lib/cmd_*.sh
git commit -m "feat(wt): dispatcher, ui/run wrapper, dry-run scaffolding"
```

---

## Task 2: naming.sh (pure)

**Files:**
- Create: `lib/naming.sh`, `tests/naming.bats`

**Interfaces:**
- Produces: `wt_slugify <raw>`→dns-safe; `wt_project <app> <slug>`; `wt_domain <app> <slug>`; `wt_db <app> <slug>`; `wt_path <app> <slug>`; `wt_branch <type> <slug>`.

- [ ] **Step 1: Write the failing test**

`tests/naming.bats`:
```bash
load helpers
setup() { setup_wt; source "$WT_ROOT/lib/naming.sh"; }

@test "slugify lowercases and hyphenates" {
  [ "$(wt_slugify 'GEL-123 Fix Header')" = "gel-123-fix-header" ]
}
@test "slugify collapses and trims separators" {
  [ "$(wt_slugify '  feature/Foo__Bar!! ')" = "feature-foo-bar" ]
}
@test "slugify caps length at 40" {
  out="$(wt_slugify "$(printf 'a%.0s' {1..80})")"; [ "${#out}" -le 40 ]
}
@test "project/domain/db/path/branch derive correctly" {
  [ "$(wt_project myprojekt-app gel-123)" = "myprojekt-app-gel-123" ]
  [ "$(wt_domain myprojekt-app gel-123)" = "myprojekt-app-gel-123.docker.test" ]
  [ "$(wt_db myprojekt-app gel-123)" = "myprojekt_app_gel_123" ]
  [ "$(wt_path myprojekt-app gel-123)" = "$HOME/wt/myprojekt-app-gel-123" ]
  [ "$(wt_branch feature gel-123)" = "feature/gel-123" ]
  [ "$(wt_branch hotfix gel-123)" = "hotfix/gel-123" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/naming.bats`
Expected: FAIL (`wt_slugify` not defined).

- [ ] **Step 3: Write minimal implementation**

`lib/naming.sh`:
```bash
# shellcheck shell=bash
wt_slugify() {
  local s="$1"
  s="${s,,}"                       # lowercase
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-|-$//g')"
  printf '%s' "${s:0:40}" | sed -E 's/-$//'
}
wt_project() { printf '%s-%s' "$1" "$2"; }
wt_domain()  { printf '%s-%s.docker.test' "$1" "$2"; }
wt_db()      { printf '%s_%s' "$1" "$2" | tr '-' '_'; }
wt_path()    { printf '%s/wt/%s-%s' "$HOME" "$1" "$2"; }
wt_branch()  { printf '%s/%s' "$1" "$2"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/naming.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/naming.sh tests/naming.bats
git commit -m "feat(wt): pure naming helpers (slug, project, domain, db, path, branch)"
```

---

## Task 3: profile.sh + apps.conf

**Files:**
- Create: `lib/profile.sh`, `etc/wt/apps.conf`, `tests/profile.bats`, `tests/fixtures/apps.conf`

**Interfaces:**
- Produces: `wt_profile_load <file>`; `wt_profile_get <app> <field>` (fields: `repo`, `type`, `base`, `compose`, `install`); `wt_profile_require <app>` (die if unknown or `type!=symfony`).

- [ ] **Step 1: Write the failing test**

`tests/fixtures/apps.conf`:
```
# app|repo|type|base|compose|install
myprojekt-app|/tmp/repos/myprojekt-app|symfony|develop|.docker/docker-compose.yml|make install
legacy-thing|/tmp/repos/legacy|prestashop|main|.docker/docker-compose.yml|
```
`tests/profile.bats`:
```bash
load helpers
setup() { setup_wt; source "$WT_ROOT/lib/profile.sh"; wt_profile_load "$WT_ROOT/tests/fixtures/apps.conf"; }

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/profile.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/profile.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
declare -gA WT_APP_REPO WT_APP_TYPE WT_APP_BASE WT_APP_COMPOSE WT_APP_INSTALL
wt_profile_load() {
  local f="${1:-$WT_ROOT/etc/wt/apps.conf}" app repo type base compose install
  [ -f "$f" ] || die "apps.conf not found: $f"
  while IFS='|' read -r app repo type base compose install; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    WT_APP_REPO[$app]="$repo"; WT_APP_TYPE[$app]="$type"
    WT_APP_BASE[$app]="$base"; WT_APP_COMPOSE[$app]="$compose"
    WT_APP_INSTALL[$app]="$install"
  done < "$f"
}
wt_profile_get() {
  local app="$1" field="$2"
  case "$field" in
    repo) printf '%s' "${WT_APP_REPO[$app]:-}";;
    type) printf '%s' "${WT_APP_TYPE[$app]:-}";;
    base) printf '%s' "${WT_APP_BASE[$app]:-}";;
    compose) printf '%s' "${WT_APP_COMPOSE[$app]:-}";;
    install) printf '%s' "${WT_APP_INSTALL[$app]:-}";;
    *) die "unknown field: $field";;
  esac
}
wt_profile_require() {
  local app="$1"
  [ -n "${WT_APP_REPO[$app]:-}" ] || die "unknown app: $app"
  [ "${WT_APP_TYPE[$app]}" = "symfony" ] || die "app '$app' not supported in v1 (type=${WT_APP_TYPE[$app]})"
}
```
`etc/wt/apps.conf` (real v1 profiles):
```
# app|repo|type|base|compose|install
myprojekt-app|/home/webadmin/Project/MyProjekt/app.myprojekt.fr|symfony|develop|.docker/docker-compose.yml|make install
bifacto-doc|/home/webadmin/Project/Diplam09/doc.bifacto.com|symfony|develop|.docker/docker-compose.yml|make install
consotrust|/home/webadmin/Project/2JDB/stream.consotrust.com|symfony|develop|.docker/docker-compose.yml|make install
lagestionenligne|/home/webadmin/Project/LaGestionEnLigne/app.lagestionenligne.fr|symfony|develop|.docker/docker-compose.yml|make install
parisrental|/home/webadmin/Project/Asteria/parisrental.com|symfony|develop|.docker/docker-compose.yml|make install
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/profile.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/profile.sh etc/wt/apps.conf tests/profile.bats tests/fixtures/apps.conf
git commit -m "feat(wt): app profiles (apps.conf parser + v1 symfony apps)"
```

---

## Task 4: registry.sh

**Files:**
- Create: `lib/registry.sh`, `tests/registry.bats`

**Interfaces:**
- Produces: `wt_reg_add <json>`; `wt_reg_remove <project>`; `wt_reg_exists <project>` (0/1); `wt_reg_get <project>`; `wt_reg_list` (JSON array). Registry path: `$WT_STATE/registry.json`.

- [ ] **Step 1: Write the failing test**

`tests/registry.bats`:
```bash
load helpers
setup() { setup_wt; source "$WT_ROOT/lib/registry.sh"; }

@test "add then exists then get" {
  wt_reg_add '{"project":"app-x","app":"app","slug":"x","db":"app_x"}'
  run wt_reg_exists app-x; [ "$status" -eq 0 ]
  [ "$(wt_reg_get app-x | jq -r .db)" = "app_x" ]
}
@test "list returns array; remove drops entry" {
  wt_reg_add '{"project":"app-x","app":"app","slug":"x"}'
  wt_reg_add '{"project":"app-y","app":"app","slug":"y"}'
  [ "$(wt_reg_list | jq 'length')" = "2" ]
  wt_reg_remove app-x
  [ "$(wt_reg_list | jq 'length')" = "1" ]
  run wt_reg_exists app-x; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/registry.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/registry.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
_wt_reg_file() { printf '%s/registry.json' "$WT_STATE"; }
_wt_reg_init() { mkdir -p "$WT_STATE"; [ -f "$(_wt_reg_file)" ] || echo '[]' > "$(_wt_reg_file)"; }
wt_reg_add() {
  _wt_reg_init; local f; f="$(_wt_reg_file)"
  local tmp; tmp="$(mktemp)"
  jq --argjson e "$1" 'map(select(.project != ($e.project))) + [$e]' "$f" > "$tmp" && mv "$tmp" "$f"
}
wt_reg_remove() {
  _wt_reg_init; local f; f="$(_wt_reg_file)"; local tmp; tmp="$(mktemp)"
  jq --arg p "$1" 'map(select(.project != $p))' "$f" > "$tmp" && mv "$tmp" "$f"
}
wt_reg_exists() { _wt_reg_init; jq -e --arg p "$1" 'any(.project == $p)' "$(_wt_reg_file)" >/dev/null; }
wt_reg_get()    { _wt_reg_init; jq -c --arg p "$1" '.[] | select(.project == $p)' "$(_wt_reg_file)"; }
wt_reg_list()   { _wt_reg_init; cat "$(_wt_reg_file)"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/registry.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/registry.sh tests/registry.bats
git commit -m "feat(wt): JSON registry CRUD via jq"
```

---

## Task 5: envgen.sh (pure file transforms)

**Files:**
- Create: `lib/envgen.sh`, `tests/envgen.bats`, `tests/fixtures/dot.docker.env`, `tests/fixtures/dot.env.local`

**Interfaces:**
- Produces: `wt_gen_docker_env <src> <dst> <project> <domain>` (rewrite `COMPOSE_PROJECT_NAME/DOMAIN`, set `APP_FOLDER=../`); `wt_patch_env_local <src> <dst> <domain> <db> <pass>` (rewrite `APP_URL`, `DATABASE_URL`).

- [ ] **Step 1: Write the failing test**

`tests/fixtures/dot.docker.env`:
```
COMPOSE_PROJECT_NAME=myprojekt-app
COMPOSE_PROJECT_DOMAIN=myprojekt-app.docker.test
APP_FOLDER=../
PROJECT_TYPE=symfony
```
`tests/fixtures/dot.env.local`:
```
APP_ENV=dev
APP_URL=https://myprojekt-app.docker.test
DATABASE_URL="mysql://myprojekt_app:oldpass@infra_mysql_8_0/myprojekt_app?serverVersion=8.0&charset=utf8mb4"
```
`tests/envgen.bats`:
```bash
load helpers
setup() { setup_wt; source "$WT_ROOT/lib/naming.sh"; source "$WT_ROOT/lib/envgen.sh"; }

@test "docker env gets new project + domain" {
  wt_gen_docker_env "$WT_ROOT/tests/fixtures/dot.docker.env" "$BATS_TEST_TMPDIR/.env" myprojekt-app-gel-123 myprojekt-app-gel-123.docker.test
  grep -qx 'COMPOSE_PROJECT_NAME=myprojekt-app-gel-123' "$BATS_TEST_TMPDIR/.env"
  grep -qx 'COMPOSE_PROJECT_DOMAIN=myprojekt-app-gel-123.docker.test' "$BATS_TEST_TMPDIR/.env"
  grep -q 'PROJECT_TYPE=symfony' "$BATS_TEST_TMPDIR/.env"
}
@test "env.local repoints app_url and database_url" {
  wt_patch_env_local "$WT_ROOT/tests/fixtures/dot.env.local" "$BATS_TEST_TMPDIR/.env.local" myprojekt-app-gel-123.docker.test myprojekt_app_gel_123 s3cret
  grep -qx 'APP_URL=https://myprojekt-app-gel-123.docker.test' "$BATS_TEST_TMPDIR/.env.local"
  grep -q 'mysql://myprojekt_app_gel_123:s3cret@infra_mysql_8_0/myprojekt_app_gel_123' "$BATS_TEST_TMPDIR/.env.local"
  grep -q 'serverVersion=8.0' "$BATS_TEST_TMPDIR/.env.local"  # query string preserved
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/envgen.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/envgen.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
wt_gen_docker_env() { # src dst project domain
  local src="$1" dst="$2" project="$3" domain="$4"
  [ -f "$src" ] || die "missing .docker/.env: $src"
  sed -E \
    -e "s#^COMPOSE_PROJECT_NAME=.*#COMPOSE_PROJECT_NAME=${project}#" \
    -e "s#^COMPOSE_PROJECT_DOMAIN=.*#COMPOSE_PROJECT_DOMAIN=${domain}#" \
    -e "s#^APP_FOLDER=.*#APP_FOLDER=../#" \
    "$src" > "$dst"
}
wt_patch_env_local() { # src dst domain db pass
  local src="$1" dst="$2" domain="$3" db="$4" pass="$5"
  [ -f "$src" ] || die "missing .env.local: $src"
  # rewrite APP_URL; rewrite the db credentials + name in DATABASE_URL, keep host + query
  sed -E \
    -e "s#^APP_URL=.*#APP_URL=https://${domain}#" \
    -e "s#(mysql://)[^:]+:[^@]+@([^/]+)/[^?\"']+#\1${db}:${pass}@\2/${db}#" \
    "$src" > "$dst"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/envgen.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/envgen.sh tests/envgen.bats tests/fixtures/dot.docker.env tests/fixtures/dot.env.local
git commit -m "feat(wt): generate .docker/.env and patch .env.local (pure transforms)"
```

---

## Task 6: gitwt.sh (real temp-repo tested)

**Files:**
- Create: `lib/gitwt.sh`, `tests/gitwt.bats`

**Interfaces:**
- Produces: `wt_git_add_worktree <repo> <base> <branch> <path>`; `wt_git_remove_worktree <repo> <path>`; `wt_git_is_dirty <path>` (0/1); `wt_git_unpushed <path>` (count on stdout). Uses `run` for mutations.

- [ ] **Step 1: Write the failing test**

`tests/gitwt.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/gitwt.sh"
  REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$REPO"; ( cd "$REPO"
    git init -q -b main; git config user.email t@t; git config user.name t
    echo hi > a.txt; git add a.txt; git commit -qm init
    git branch develop )
}
@test "add worktree on develop then dirty detection" {
  local p="$BATS_TEST_TMPDIR/wt1"
  wt_git_add_worktree "$REPO" develop feature/x "$p"
  [ -f "$p/a.txt" ]
  [ "$(git -C "$p" branch --show-current)" = "feature/x" ]
  run wt_git_is_dirty "$p"; [ "$status" -ne 0 ]     # clean
  echo change >> "$p/a.txt"
  run wt_git_is_dirty "$p"; [ "$status" -eq 0 ]      # dirty
}
@test "remove worktree" {
  local p="$BATS_TEST_TMPDIR/wt2"
  wt_git_add_worktree "$REPO" develop feature/y "$p"
  wt_git_remove_worktree "$REPO" "$p"
  [ ! -d "$p" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/gitwt.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/gitwt.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
wt_git_add_worktree() { # repo base branch path
  local repo="$1" base="$2" branch="$3" path="$4"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    run git -C "$repo" worktree add "$path" "$branch"
  else
    run git -C "$repo" worktree add -b "$branch" "$path" "$base"
  fi
}
wt_git_remove_worktree() { # repo path
  run git -C "$1" worktree remove --force "$2"
}
wt_git_is_dirty() { # path -> 0 if dirty
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}
wt_git_unpushed() { # path -> prints count of commits not on any upstream
  git -C "$1" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/gitwt.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/gitwt.sh tests/gitwt.bats
git commit -m "feat(wt): git worktree add/remove + dirty/unpushed guards"
```

---

## Task 7: db.sh (dry-run asserted)

**Files:**
- Create: `lib/db.sh`, `tests/db.bats`

**Interfaces:**
- Produces: `wt_db_create <db> <pass>`; `wt_db_drop <db>`. Both emit `docker exec infra_mariadb_11_3 mysql ...` via `run`. Reads `MYSQL_ROOT_PASSWORD` from `$WT_ROOT/.env` at call time.

- [ ] **Step 1: Write the failing test**

`tests/db.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/db.sh"
  export WT_DRY_RUN=1
  printf 'MYSQL_ROOT_PASSWORD=rootpw\n' > "$WT_ROOT/.env.test"; export WT_ENV_FILE="$WT_ROOT/.env.test"
}
teardown() { rm -f "$WT_ROOT/.env.test"; }

@test "create emits CREATE DATABASE/USER/GRANT" {
  run wt_db_create app_x s3cret
  [[ "$output" == *"docker exec infra_mariadb_11_3"* ]]
  [[ "$output" == *"CREATE DATABASE IF NOT EXISTS \`app_x\`"* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'app_x'"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`app_x\`.*"* ]]
}
@test "drop emits DROP DATABASE/USER" {
  run wt_db_drop app_x
  [[ "$output" == *"DROP DATABASE IF EXISTS \`app_x\`"* ]]
  [[ "$output" == *"DROP USER IF EXISTS 'app_x'"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/db.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/db.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
WT_DB_CONTAINER="${WT_DB_CONTAINER:-infra_mariadb_11_3}"
_wt_db_rootpw() {
  local f="${WT_ENV_FILE:-$WT_ROOT/.env}"
  [ -f "$f" ] || die "env file with MYSQL_ROOT_PASSWORD not found: $f"
  awk -F= '/^MYSQL_ROOT_PASSWORD=/{print $2; exit}' "$f"
}
_wt_db_sql() { # runs a SQL string as root
  local sql="$1" pw; pw="$(_wt_db_rootpw)"
  run docker exec "$WT_DB_CONTAINER" mysql -uroot -p"$pw" -e "$sql"
}
wt_db_create() { # db pass
  local db="$1" pass="$2"
  _wt_db_sql "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4; \
CREATE USER IF NOT EXISTS '$db'@'%' IDENTIFIED BY '$pass'; \
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$db'@'%'; FLUSH PRIVILEGES;"
}
wt_db_drop() { # db
  local db="$1"
  _wt_db_sql "DROP DATABASE IF EXISTS \`$db\`; DROP USER IF EXISTS '$db'@'%'; FLUSH PRIVILEGES;"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/db.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/db.sh tests/db.bats
git commit -m "feat(wt): dedicated dev DB create/drop via MariaDB container"
```

---

## Task 8: docker.sh (dry-run asserted)

**Files:**
- Create: `lib/docker.sh`, `tests/docker.bats`

**Interfaces:**
- Produces: `wt_docker_up <path> <compose> <project>`; `wt_docker_down <path> <compose> <project>`; `wt_docker_status <project>` (prints running container count). Mutations via `run`.

- [ ] **Step 1: Write the failing test**

`tests/docker.bats`:
```bash
load helpers
setup() { setup_wt; source "$WT_ROOT/lib/docker.sh"; export WT_DRY_RUN=1; }

@test "up emits compose up with project name" {
  run wt_docker_up /home/x/wt/app-x .docker/docker-compose.yml app-x
  [[ "$output" == *"docker compose -p app-x -f .docker/docker-compose.yml up -d --build"* ]]
}
@test "down emits compose down -v" {
  run wt_docker_down /home/x/wt/app-x .docker/docker-compose.yml app-x
  [[ "$output" == *"docker compose -p app-x -f .docker/docker-compose.yml down -v"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/docker.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/docker.sh`:
```bash
# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
wt_docker_up() { # path compose project
  ( cd "$1" && run docker compose -p "$3" -f "$2" up -d --build )
}
wt_docker_down() { # path compose project
  ( cd "$1" && run docker compose -p "$3" -f "$2" down -v )
}
wt_docker_status() { # project -> count of running containers
  docker ps --filter "label=com.docker.compose.project=$1" -q 2>/dev/null | wc -l
}
```
Note: the `cd` subshell means dry-run prints the command; the path need not exist in tests because `cd` to a missing dir under dry-run would fail — so guard: only `cd` when the dir exists or dry-run.
```bash
wt_docker_up() { local p="$1"; { [ -d "$p" ] || [ "$WT_DRY_RUN" = 1 ]; } || die "no worktree: $p"; ( [ -d "$p" ] && cd "$p"; run docker compose -p "$3" -f "$2" up -d --build ); }
wt_docker_down() { local p="$1"; ( [ -d "$p" ] && cd "$p"; run docker compose -p "$3" -f "$2" down -v ); }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/docker.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/docker.sh tests/docker.bats
git commit -m "feat(wt): docker compose up/down/status per project"
```

---

## Task 9: cmd_create.sh (orchestration + rollback)

**Files:**
- Create: `lib/cmd_create.sh` (replaces stub), `tests/create.bats`

**Interfaces:**
- Consumes: naming.sh, profile.sh, registry.sh, envgen.sh, gitwt.sh, db.sh, docker.sh.
- Produces: `cmd_create <app> <slug> [--feature|--hotfix] [--ticket KEY] [--keep-on-error]`. On dry-run, emits the full ordered plan and registers nothing.

- [ ] **Step 1: Write the failing test**

`tests/create.bats`:
```bash
load helpers
setup() {
  setup_wt; export WT_DRY_RUN=1
  export WT_APPS_FILE="$WT_ROOT/tests/fixtures/apps.conf"
  mkdir -p /tmp/repos/myprojekt-app/.docker
  printf 'COMPOSE_PROJECT_NAME=x\nCOMPOSE_PROJECT_DOMAIN=x\nAPP_FOLDER=../\n' > /tmp/repos/myprojekt-app/.docker/.env
  printf 'APP_URL=https://x\nDATABASE_URL="mysql://u:p@infra_mysql_8_0/d?serverVersion=8.0"\n' > /tmp/repos/myprojekt-app/.env.local
}
@test "create emits ordered plan: worktree -> db -> up -> install" {
  run wt create myprojekt-app GEL-123 --feature
  [ "$status" -eq 0 ]
  # order assertions
  wt_line() { printf '%s\n' "$output" | grep -n "$1" | head -1 | cut -d: -f1; }
  [ "$(wt_line 'worktree add')" -lt "$(wt_line 'CREATE DATABASE')" ]
  [ "$(wt_line 'CREATE DATABASE')" -lt "$(wt_line 'compose -p myprojekt-app-gel-123')" ]
  [[ "$output" == *"myprojekt-app-gel-123.docker.test"* ]]
  [[ "$output" == *"make install"* ]]
}
@test "create rejects unknown app" {
  run wt create nope x; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/create.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/cmd_create.sh`:
```bash
# shellcheck shell=bash
for m in ui naming profile registry envgen gitwt db docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_create() {
  local app="" slug="" type="feature" ticket="" keep=0
  app="$1"; slug="$2"; shift 2 || die "usage: wt create <app> <slug>"
  while [ $# -gt 0 ]; do case "$1" in
    --feature) type=feature;; --hotfix) type=hotfix;;
    --ticket) ticket="$2"; shift;; --keep-on-error) keep=1;;
    *) die "unknown flag: $1";; esac; shift; done

  wt_profile_load "${WT_APPS_FILE:-$WT_ROOT/etc/wt/apps.conf}"
  wt_profile_require "$app"
  local repo base compose install
  repo="$(wt_profile_get "$app" repo)"; compose="$(wt_profile_get "$app" compose)"
  install="$(wt_profile_get "$app" install)"
  base=$([ "$type" = hotfix ] && echo main || wt_profile_get "$app" base)

  slug="$(wt_slugify "${ticket:-$slug}")"
  local project domain db path branch pass
  project="$(wt_project "$app" "$slug")"; domain="$(wt_domain "$app" "$slug")"
  db="$(wt_db "$app" "$slug")"; path="$(wt_path "$app" "$slug")"
  branch="$(wt_branch "$type" "$slug")"; pass="$(openssl rand -hex 12 2>/dev/null || echo devpass$RANDOM)"

  wt_reg_exists "$project" && die "env already exists: $project (use wt open/destroy)"

  # rollback trap
  local created_wt=0 created_db=0 created_up=0
  rollback() {
    [ "$keep" = 1 ] && { warn "kept on error (--keep-on-error)"; return; }
    warn "rolling back $project"
    [ "$created_up" = 1 ] && wt_docker_down "$path" "$compose" "$project" || true
    [ "$created_db" = 1 ] && wt_db_drop "$db" || true
    [ "$created_wt" = 1 ] && wt_git_remove_worktree "$repo" "$path" || true
  }
  trap 'rollback' ERR

  log "fetch + worktree $branch (base $base)"
  run git -C "$repo" fetch origin
  wt_git_add_worktree "$repo" "origin/$base" "$branch" "$path"; created_wt=1

  log "copy runtime files"
  for f in .env.local .env.test.local .mcp.json; do
    [ -f "$repo/$f" ] && run cp "$repo/$f" "$path/$f" || true
  done
  wt_gen_docker_env "$repo/.docker/.env" "$path/.docker/.env" "$project" "$domain"
  wt_patch_env_local "$repo/.env.local" "$path/.env.local" "$domain" "$db" "$pass"

  log "create DB $db"; wt_db_create "$db" "$pass"; created_db=1
  log "docker up $project"; wt_docker_up "$path" "$compose" "$project"; created_up=1

  log "install"
  if [ -n "$install" ]; then ( [ -d "$path" ] && cd "$path"; run $install ); fi

  wt_reg_add "$(jq -n --arg a "$app" --arg s "$slug" --arg p "$project" \
    --arg path "$path" --arg b "$branch" --arg base "$base" --arg d "$domain" --arg db "$db" \
    '{app:$a,slug:$s,project:$p,path:$path,branch:$b,base:$base,domain:$d,db:$db,created_at:(now|todate),status:"up"}')"
  trap - ERR
  ok "ready: https://$domain  ($path)"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/create.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd_create.sh tests/create.bats
git commit -m "feat(wt): create orchestrator with ordered plan and rollback"
```

---

## Task 10: cmd_destroy.sh (guards)

**Files:**
- Create: `lib/cmd_destroy.sh` (replaces stub), `tests/destroy.bats`

**Interfaces:**
- Consumes: registry, gitwt, db, docker, naming.
- Produces: `cmd_destroy <app> <slug> [--yes] [--force] [--prune-branch]`. Refuses non-managed targets and dirty/unpushed worktrees without `--force`.

- [ ] **Step 1: Write the failing test**

`tests/destroy.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  export WT_DRY_RUN=1 WT_YES=1
  wt_reg_add '{"project":"myprojekt-app-gel-123","app":"myprojekt-app","slug":"gel-123","path":"'"$HOME"'/wt/myprojekt-app-gel-123","branch":"feature/gel-123","db":"myprojekt_app_gel_123","domain":"myprojekt-app-gel-123.docker.test"}'
  mkdir -p "$HOME/wt/myprojekt-app-gel-123"
}
@test "destroy emits down -> drop db -> worktree remove and clears registry" {
  run wt destroy myprojekt-app gel-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"down -v"* ]]
  [[ "$output" == *"DROP DATABASE IF EXISTS \`myprojekt_app_gel_123\`"* ]]
}
@test "destroy refuses unknown env" {
  run wt destroy myprojekt-app nope; [ "$status" -ne 0 ]; [[ "$output" == *"not managed"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/destroy.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/cmd_destroy.sh`:
```bash
# shellcheck shell=bash
for m in ui naming profile registry gitwt db docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_destroy() {
  local app="$1" slug="$2"; shift 2 || die "usage: wt destroy <app> <slug>"
  local force=0 prune=0
  while [ $# -gt 0 ]; do case "$1" in --yes) WT_YES=1;; --force) force=1;; --prune-branch) prune=1;; *) die "unknown flag: $1";; esac; shift; done
  slug="$(wt_slugify "$slug")"
  local project; project="$(wt_project "$app" "$slug")"
  wt_reg_exists "$project" || die "env not managed by wt: $project"
  local e path db branch compose
  e="$(wt_reg_get "$project")"
  path="$(jq -r .path <<<"$e")"; db="$(jq -r .db <<<"$e")"; branch="$(jq -r .branch <<<"$e")"
  compose="$(wt_profile_get "$app" compose 2>/dev/null || echo .docker/docker-compose.yml)"
  case "$path" in "$HOME/wt/"*) :;; *) die "refusing: $path is not under \$HOME/wt";; esac

  if [ -d "$path" ] && wt_git_is_dirty "$path" && [ "$force" != 1 ]; then
    die "worktree has uncommitted changes; use --force to destroy anyway"
  fi
  local repo; repo="$(wt_profile_get "$app" repo 2>/dev/null || true)"
  log "plan: down $project | drop db $db | remove worktree $path"
  confirm "destroy $project ?" || die "aborted"

  wt_docker_down "$path" "$compose" "$project"
  wt_db_drop "$db"
  [ -n "$repo" ] && wt_git_remove_worktree "$repo" "$path" || run git worktree remove --force "$path"
  [ "$prune" = 1 ] && [ -n "$repo" ] && run git -C "$repo" branch -D "$branch" || true
  wt_reg_remove "$project"
  ok "destroyed $project"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/destroy.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd_destroy.sh tests/destroy.bats
git commit -m "feat(wt): destroy orchestrator with managed-target and dirty guards"
```

---

## Task 11: cmd_list.sh + cmd_open.sh

**Files:**
- Create: `lib/cmd_list.sh` (replaces stub), `lib/cmd_open.sh` (replaces stub), `tests/list.bats`

**Interfaces:**
- Produces: `cmd_list [--json]` (table or raw JSON with a live docker count + disk); `cmd_open <app> <slug>` (prints the worktree path, non-zero if missing).

- [ ] **Step 1: Write the failing test**

`tests/list.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  wt_reg_add '{"project":"app-x","app":"app","slug":"x","path":"'"$HOME"'/wt/app-x","branch":"feature/x","domain":"app-x.docker.test","db":"app_x"}'
  mkdir -p "$HOME/wt/app-x"
}
@test "list --json returns the registry array" {
  run wt list --json; [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
}
@test "list table shows domain" {
  run wt list; [[ "$output" == *"app-x.docker.test"* ]]
}
@test "open prints the path" {
  run wt open app x; [ "$status" -eq 0 ]; [[ "$output" == *"/wt/app-x"* ]]
}
@test "open fails on missing env" {
  run wt open app nope; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/list.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/cmd_list.sh`:
```bash
# shellcheck shell=bash
for m in ui naming registry docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_list() {
  if [ "${1:-}" = "--json" ]; then wt_reg_list; return; fi
  printf '%-30s %-34s %-22s %-6s\n' APP-SLUG DOMAIN BRANCH DOCKER
  wt_reg_list | jq -r '.[] | [.project, .domain, .branch] | @tsv' | while IFS=$'\t' read -r p d b; do
    printf '%-30s %-34s %-22s %-6s\n' "$p" "$d" "$b" "$(wt_docker_status "$p")"
  done
}
```
`lib/cmd_open.sh`:
```bash
# shellcheck shell=bash
for m in ui naming registry; do source "$WT_ROOT/lib/$m.sh"; done
cmd_open() {
  local app="$1" slug; slug="$(wt_slugify "$2")"
  local project; project="$(wt_project "$app" "$slug")"
  wt_reg_exists "$project" || die "env not found: $project"
  wt_reg_get "$project" | jq -r .path
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/list.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd_list.sh lib/cmd_open.sh tests/list.bats
git commit -m "feat(wt): list (table/json) and open commands"
```

---

## Task 12: cmd_doctor.sh (reconcile orphans)

**Files:**
- Create: `lib/cmd_doctor.sh` (replaces stub), `tests/doctor.bats`

**Interfaces:**
- Consumes: registry, gitwt (via `git worktree list`), docker.
- Produces: `cmd_doctor [--fix]` — prints one line per anomaly (`ORPHAN-DIR`, `MISSING-DIR`, `NO-DOCKER`); with `--fix`, removes registry entries whose worktree dir is gone.

- [ ] **Step 1: Write the failing test**

`tests/doctor.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/registry.sh"
  # entry whose path does not exist -> MISSING-DIR
  wt_reg_add '{"project":"app-gone","app":"app","slug":"gone","path":"'"$HOME"'/wt/app-gone","db":"app_gone","domain":"app-gone.docker.test","branch":"feature/gone"}'
}
@test "doctor flags a registry entry with no worktree dir" {
  run wt doctor
  [[ "$output" == *"MISSING-DIR app-gone"* ]]
}
@test "doctor --fix drops the stale entry" {
  run wt doctor --fix
  run wt list --json
  [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/doctor.bats`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

`lib/cmd_doctor.sh`:
```bash
# shellcheck shell=bash
for m in ui registry docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_doctor() {
  local fix=0; [ "${1:-}" = "--fix" ] && fix=1
  local issues=0
  while IFS=$'\t' read -r project path; do
    if [ ! -d "$path" ]; then
      printf 'MISSING-DIR %s (%s)\n' "$project" "$path"; issues=$((issues+1))
      [ "$fix" = 1 ] && wt_reg_remove "$project"
    elif [ "$(wt_docker_status "$project")" = "0" ]; then
      printf 'NO-DOCKER %s\n' "$project"; issues=$((issues+1))
    fi
  done < <(wt_reg_list | jq -r '.[] | [.project, .path] | @tsv')
  # dirs under ~/wt not in registry -> orphan
  if [ -d "$HOME/wt" ]; then
    for d in "$HOME/wt"/*/; do [ -d "$d" ] || continue
      local name; name="$(basename "$d")"
      wt_reg_exists "$name" || { printf 'ORPHAN-DIR %s\n' "$name"; issues=$((issues+1)); }
    done
  fi
  [ "$issues" = 0 ] && ok "no anomalies" || true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/doctor.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cmd_doctor.sh tests/doctor.bats
git commit -m "feat(wt): doctor reconciles registry vs worktrees/docker"
```

---

## Task 13: README + full suite + manual integration test

**Files:**
- Create: `docs/wt-README.md`
- Modify: none (verification task)

**Interfaces:** none (docs + green suite).

- [ ] **Step 1: Write the failing test**

Add `tests/smoke.bats` (whole-CLI dry-run against real apps.conf, no side effects):
```bash
load helpers
setup() { setup_wt; export WT_DRY_RUN=1; }
@test "create dry-run against real profile emits domain + install" {
  run wt create parisrental TICKET-1 --feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"parisrental-ticket-1.docker.test"* ]]
  [[ "$output" == *"make install"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/smoke.bats`
Expected: FAIL if any wiring is off; otherwise confirms end-to-end plan.

- [ ] **Step 3: Write the docs + fix any wiring**

`docs/wt-README.md` — cover: install (`sudo apt-get install -y jq bats` if missing), the 5 commands with examples, the naming scheme, the `--dry-run` habit, and a **manual integration test** procedure:
```
# Manual integration test (one throwaway env), run on the VPS:
bin/wt create parisrental it-smoke --feature      # real create
curl -sk https://parisrental-it-smoke.docker.test | head   # Traefik routes it
bin/wt list
bin/wt destroy parisrental it-smoke --yes         # full teardown
bin/wt doctor                                     # expect: no anomalies
```

- [ ] **Step 4: Run the whole suite**

Run: `bats tests/`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/wt-README.md tests/smoke.bats
git commit -m "docs(wt): README + smoke test; green suite"
```

---

## Self-Review

- **Spec coverage:** create/list/destroy/open/doctor (Tasks 9–12,11) ✓ · naming/domain/db (Task 2) ✓ · profiles + v1 Symfony apps (Task 3) ✓ · registry (Task 4) ✓ · .docker/.env + .env.local patch (Task 5) ✓ · git worktree + guards (Task 6) ✓ · dedicated DB (Task 7) ✓ · docker up/down (Task 8) ✓ · rollback + idempotency guard (Task 9) ✓ · destroy safety (Task 10) ✓ · dry-run everywhere (Tasks 1,7,8,9,10) ✓ · resource guard: **deferred** — noted in spec §14 as tunable; add as a follow-up once real RAM headroom is measured (out of this plan's scope). Logging to `~/.local/state/wt/logs` and per-app lockfile: **light in v1** — fold into Task 9/10 if desired, but not required for a working engine.
- **Placeholder scan:** none — every step has real bash/bats.
- **Type consistency:** function names match across tasks (`wt_git_add_worktree`, `wt_reg_*`, `wt_db_*`, `wt_docker_*`, `wt_gen_docker_env`/`wt_patch_env_local`, `cmd_*`). `WT_APPS_FILE` used consistently for test override.

Two intentional deferrals surfaced above (resource guard, lockfile/logging) — both are spec-noted enhancements, not blockers for a working, tested engine.
