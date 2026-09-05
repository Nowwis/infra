# Dashboard `worktree.docker.test`

A small web dashboard for observing and lightly steering the worktree host: system
load, running docker containers, worktree environments, active Claude sessions, and
disk usage — plus a couple of safe actions. It is a **client** of the `wt` engine
(no duplicated logic): it reads what `wt list --json`, `docker stats`, and the host
already know, and shells out to `wt destroy` for the one mutating action.

## What it shows

`bin/wt-metrics all` aggregates five sections, each fail-safe (a section degrades to
`{}`/`[]` if its underlying command is unavailable or fails — it never breaks the
others):

- **system** — RAM/swap usage, load average, core count, CPU pressure (PSI).
- **docker** — running containers: name, compose project, CPU %, memory.
- **worktrees** — `wt list --json` entries enriched with on-disk size (`du -sb`).
- **sessions** — Claude Code processes on the host: pid, kind (`claude` /
  `remote-control` / `sdk-backend`), model, RSS, CPU %, age.
- **disk** — `df` per mount point (size/used/available/use %).

The frontend (`dashboard/public/`) polls `GET /api/metrics` every ~3s and renders
gauges for `system`, tables for the rest, plus small in-memory sparklines (never
persisted, never sent anywhere). `GET /api/metrics.csv` exports the same data
flattened as CSV (the "Export CSV" button in the top bar).

## Safe actions

- **Destroy a worktree** — the "Supprimer" button on a worktree row asks for
  confirmation, then `POST /api/worktrees/{project}/destroy`. The backend looks
  `{project}` up in `wt list --json`; unknown projects are refused (404) without
  ever passing the caller-supplied value to a shell. Only the registry-resolved
  `app`/`slug` are passed to `wt destroy … --yes`.
- **Open an app** — the "Ouvrir" link on a worktree row opens its app URL
  (`https://<app>-<slug>.docker.test`) in a new tab. Read-only, no backend call.

There is no way to stop/kill a session or a docker stack from the UI (v2), and no
metric history beyond the in-memory sparklines (v2).

## Prerequisites

- `php` (CLI, with the built-in `php -S` dev server) — runs the backend and serves
  the static frontend.
- `jq` — used by `bin/wt-metrics` to shape every collector's JSON output.
- `docker` — used for the `docker` section (`docker stats --no-stream`); the section
  degrades to `[]` if docker is not available.
- `wt` (this repo's `bin/wt`) — used for the `worktrees` section and for the destroy
  action.

## Install / uninstall

```bash
bin/wt-dash-install              # install: systemd --user unit + Traefik route
bin/wt-dash-install --uninstall  # remove both, idempotently
```

Install is idempotent: re-running it does not duplicate the Traefik block (it strips
its own marker-delimited block and re-appends exactly one), and it overwrites the
systemd unit in place.

Environment variables the installer honors (all optional, with sane defaults):

| Variable             | Default                                                        | Meaning |
|----------------------|-----------------------------------------------------------------|---------|
| `WT_DASH_PORT`        | `8899`                                                          | Port the backend listens on. |
| `WT_DASH_BIND`        | `100.75.44.109` (same as `WT_DASH_HOSTADDR`, the host's Tailscale IP) | Bind address for `php -S`. |
| `WT_DASH_UNIT_DIR`    | `$HOME/.config/systemd/user`                                    | Where the systemd unit is written. |
| `WT_DASH_TRAEFIK`     | `configuration/traefik2/config/dynamic_conf.local.yaml`         | Traefik dynamic config file to patch. |
| `WT_DASH_HOSTADDR`    | `100.75.44.109` (Tailscale IP of the host)                      | Address Traefik uses to reach the backend — **must be reachable from the Traefik container**, see below. |
| `WT_DASH_BASICAUTH`   | `admin:$apr1$placeholder` (a **placeholder**, will not authenticate) | htpasswd-format `user:hash` entry for the Traefik basicauth middleware. **Generate a real one before going live** — see below. |
| `WT_DASH_RELOAD`      | unset                                                           | Set to `true` to skip the `systemctl --user daemon-reload` / `enable --now` calls (used by the test suite; leave unset for a real install). |

**Security note:** never set `WT_DASH_BIND=0.0.0.0` (or any other public-facing
address) on a host with a public IP and no host firewall — the backend API is
unauthenticated (basicauth is enforced only by the Traefik route at
`worktree.docker.test`, not by `php -S` itself), so binding it publicly would
expose `POST /api/worktrees/{project}/destroy` and the info-leaking
`GET /api/metrics` directly on `<public-ip>:8899` to anyone on the internet.

Backend-only variables (read by the PHP side, not the installer):

| Variable          | Default                              | Meaning |
|-------------------|---------------------------------------|---------|
| `WT_METRICS_BIN`  | `<repo>/bin/wt-metrics`               | Collector binary the API shells out to. |
| `WT_DASH_CACHE`   | `<tmp>/wt-dash-metrics.json`           | Metrics cache file (~2s TTL, avoids re-shelling on every poll). |
| `WT_DASH_WT`      | `<repo>/bin/wt`                       | `wt` binary used by the destroy endpoint. |

## Manual bring-up on the VPS

The installer writes the systemd unit and the Traefik route, but three things need a
human before the dashboard is safely reachable over Tailscale + basicauth:

**1. Generate a real basicauth credential.** The default (`admin:$apr1$placeholder`)
is a placeholder and will never authenticate. Generate a real htpasswd-format entry
and pass it via `WT_DASH_BASICAUTH` when installing:

```bash
htpasswd -nB admin
# New password: ********
# admin:$2y$05$....................................................
WT_DASH_BASICAUTH='admin:$2y$05$....................................................' bin/wt-dash-install
```

(Escape any `$` if you paste the hash into a shell variable rather than passing it
inline — `$$` in a literal use, or single-quote the whole assignment as above.)

**2. Confirm `WT_DASH_HOSTADDR` is reachable from the Traefik container.** The
default is the host's Tailscale IP (`100.75.44.109`), which is usually right, but
network topology varies — verify it actually resolves from inside the `traefik`
container before trusting it:

```bash
docker exec infra_traefik wget -qO- http://100.75.44.109:8899/api/metrics | head
```

If that hangs or errors, find the address Traefik can actually reach the host on
(e.g. the docker bridge gateway) and re-run the installer with
`WT_DASH_HOSTADDR=<that address>`.

**3. Enable and start the service, then open the dashboard:**

```bash
bin/wt-dash-install                       # writes the unit + Traefik block
systemctl --user enable --now wt-dashboard
systemctl --user status wt-dashboard      # confirm it's running
```

Then open `https://worktree.docker.test` — reachable only over Tailscale, and gated
by the basicauth credential from step 1.

Note: the systemd unit has no explicit ordering against `tailscaled` — if the
service starts before the Tailscale IP is up, `php -S` fails to bind and the unit
self-heals via `Restart=on-failure` (retrying until the address exists), so no boot
ordering fix has been made.

**4. Uninstall when done experimenting:**

```bash
bin/wt-dash-install --uninstall
```

### Caveat: duplicate top-level `http:` key

`bin/wt-dash-install` appends a marker-delimited `http:` block to
`configuration/traefik2/config/dynamic_conf.local.yaml`. YAML files are only allowed
one top-level `http:` key. If another tool later appends its *own* file-provider
block with a second top-level `http:` key to the same file, only one of the two
`http:` mappings survives parsing (whichever the YAML parser keeps on key collision)
and the other tool's routers/services/middlewares silently vanish from Traefik's
view. If you introduce another generator that touches this file, either merge its
routers under the same single `http:` key, or point it at a separate dynamic-config
file instead.
