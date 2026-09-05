# wt — worktree environment engine

`wt` spins up a fully isolated, throwaway environment for a ticket or a
feature: a dedicated git worktree, a dedicated database, a dedicated
docker-compose project, and a dedicated `*.docker.test` domain served by
Traefik — all from one command, and torn down just as cleanly with another.

It exists so that working on ticket A never blocks working on ticket B: no
more stashing, no more "wait, whose migration is this", no more one shared
dev database getting clobbered by two branches at once.

## Prerequisites

`wt` itself is plain bash + `jq`. Install what's missing:

```bash
sudo apt-get install -y jq bats-core
```

- `jq` is required at **runtime** — every `wt` command that touches the
  registry (`create`, `list`, `destroy`, `open`, `doctor`) shells out to it.
- `bats-core` is only needed to run the test suite (`tests/`), not to use
  the CLI day to day.

You also need `git`, `docker` (with the `compose` plugin), and `openssl`
on `$PATH` — all standard on the VPS this runs on.

## The five commands

### `wt create <app> <slug> [--feature|--hotfix] [--ticket KEY]`

Creates a new environment for `<app>` (must be listed in
`etc/wt/apps.conf`): fetches the repo, adds a git worktree on a new
`feature/<slug>` (or `hotfix/<slug>`) branch, copies over the untracked
runtime files (`.env.local`, `.env.test.local`, `.mcp.json`), generates a
scoped `.docker/.env` and patches `.env.local` to point at a dedicated
database, creates that database, brings up docker compose, runs the app's
install step, and registers the environment.

```bash
bin/wt create parisrental TICKET-1 --feature
# ...
# ✓ ready: https://parisrental-ticket-1.docker.test  (~/wt/parisrental-ticket-1)
```

`--ticket KEY` is a shorthand for using `KEY` as the slug (so
`--ticket TICKET-1` is equivalent to the positional slug `TICKET-1` above).
Add `--keep-on-error` to leave a partially-created environment in place for
inspection instead of the default automatic rollback.

### `wt list [--json]`

Lists every environment `wt` currently manages, with its domain, branch, and
running-container count. `--json` prints the raw registry array (for
scripting).

```bash
bin/wt list
APP-SLUG                       DOMAIN                             BRANCH                 DOCKER
parisrental-ticket-1           parisrental-ticket-1.docker.test   feature/ticket-1       4
```

### `wt destroy <app> <slug> [--yes] [--force] [--prune-branch]`

Tears an environment down: `docker compose down -v`, drops the database,
removes the git worktree, and de-registers it. Refuses to run outside
`$HOME/wt/`, and refuses a worktree with uncommitted changes unless
`--force`. `--yes` skips the confirmation prompt; `--prune-branch` also
deletes the local branch.

```bash
bin/wt destroy parisrental ticket-1 --yes
✓ destroyed parisrental-ticket-1
```

### `wt open <app> <slug>`

Prints the worktree's filesystem path (handy for `cd "$(wt open app slug)"`
or piping into an editor command).

```bash
cd "$(bin/wt open parisrental ticket-1)"
```

### `wt doctor [--fix]`

Sanity-checks the registry against reality: flags registry entries whose
worktree directory has disappeared (`MISSING-DIR`), entries with no running
containers (`NO-DOCKER`), and directories under `~/wt/` that aren't in the
registry at all (`ORPHAN-DIR`). `--fix` removes stale `MISSING-DIR` entries
from the registry. Prints `✓ no anomalies` when everything checks out.

```bash
bin/wt doctor
✓ no anomalies
```

## Naming scheme

Everything `wt` creates is derived deterministically from `<app>` and a
slugified `<slug>` (lowercased, non-alphanumerics collapsed to `-`, capped
at 40 chars):

| Thing              | Pattern                        | Example (`parisrental` + `TICKET-1`) |
|--------------------|---------------------------------|----------------------------------------|
| project name       | `<app>-<slug>`                  | `parisrental-ticket-1`                 |
| domain             | `<app>-<slug>.docker.test`      | `parisrental-ticket-1.docker.test`     |
| database           | `<app>_<slug>` (`-` → `_`)      | `parisrental_ticket_1`                 |
| worktree path      | `~/wt/<app>-<slug>`             | `~/wt/parisrental-ticket-1`            |
| branch (`--feature`) | `feature/<slug>` off the app's configured base (usually `develop`) | `feature/ticket-1` |
| branch (`--hotfix`)  | `hotfix/<slug>` off `main`      | `hotfix/ticket-1`                    |

## The `--dry-run` habit

Every command accepts `--dry-run` (or `WT_DRY_RUN=1` in the environment).
In dry-run mode nothing mutates: no git worktree is added, no database is
touched, no container starts, no registry entry is written — the exact
commands that *would* run are printed instead, in order, prefixed with `+`.

Get in the habit of dry-running first, especially for `create` and
`destroy` against a real app profile:

```bash
bin/wt create parisrental TICKET-1 --feature --dry-run
bin/wt destroy parisrental ticket-1 --dry-run
```

Read the plan, then drop `--dry-run` once it looks right.

## Manual integration test

The automated suite (`bats tests/`) runs entirely in dry-run mode against
fixture data, so it can't catch a real Traefik routing or docker-compose
wiring problem. Run this real (non-dry-run), throwaway procedure on the VPS
whenever you want to confirm the whole chain end to end — it creates and
then fully tears down a real, disposable environment:

```bash
bin/wt create parisrental it-smoke --feature      # real create
curl -sk https://parisrental-it-smoke.docker.test | head   # Traefik routes it
bin/wt list
bin/wt destroy parisrental it-smoke --yes         # full teardown
bin/wt doctor                                     # expect: no anomalies
```

If `doctor` reports anything after the `destroy`, the teardown left a stray
worktree, database, or container behind — treat that as a bug.
