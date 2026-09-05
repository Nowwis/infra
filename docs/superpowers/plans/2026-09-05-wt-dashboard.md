# wt — Dashboard (observability + safe controls) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A web dashboard at `worktree.docker.test` that shows VPS observability (RAM/CPU/swap/load, docker per project, worktree-envs, Claude sessions, disk) with export and safe controls (destroy a worktree-env, open an app URL), built as a thin client of the `wt` engine.

**Architecture:** Bash collectors (`bin/wt-metrics`) emit fail-safe JSON; a small host PHP backend (`php -S`, systemd --user) serves a static frontend + a fixed JSON API (metrics, csv, destroy); Traefik file-provider routes the domain to the host service behind basicauth on Tailscale. Collectors and API validation are `bats`/curl-tested; the frontend is static and manually verified.

**Tech Stack:** bash 5, `jq`, PHP 8 CLI (`php -S`), static HTML/CSS/JS (no heavy deps), `docker` CLI, `bats-core`. Builds on the `wt` engine at `bin/wt`.

**Spec:** `Project/Infra/docs/2026-09-05-wt-dashboard-design.md`

## Global Constraints

- Collectors: bash, dep `jq`, **fail-safe per section** (a failing source → `{}`/`[]`, never a non-zero abort of `wt-metrics all`).
- Backend: PHP CLI only; **fixed endpoints, no arbitrary command execution**; the only mutating endpoint (`destroy`) validates the project against `wt list --json` before calling `wt destroy <app> <slug> --yes`.
- Backend runs as the `webadmin` user (not root), on a dedicated local port (default 8899, override `WT_DASH_PORT`).
- Access is Tailscale-only + Traefik basicauth. Domain `worktree.docker.test` (wildcard → Traefik already).
- Frontend: no heavy chart lib; CSS gauges/bars + inline sparklines; theme-aware; responsive; no external CDN required.
- No Claude/AI attribution anywhere in commits or files. (The word "Claude" may appear as data — a session's process name — never as authorship.)

---

## File Structure

- `bin/wt-metrics` — collectors + `all` aggregator (JSON).
- `dashboard/public/index.html`, `dashboard/public/app.js`, `dashboard/public/style.css` — static frontend.
- `dashboard/server/router.php` — the API + static file server (run via `php -S <bind> -t dashboard/public router.php`).
- `dashboard/server/api.php` — request handling (metrics / csv / destroy) as testable functions.
- `bin/wt-dash-install` — systemd --user unit + Traefik dynamic_conf entry (idempotent, `--uninstall`).
- `tests/metrics.bats`, `tests/metrics-docker-sessions.bats`, `tests/api.bats`, `tests/dash-install.bats`, `tests/dash-smoke.bats` + reuse `tests/helpers.bash`.
- `docs/wt-dashboard-README.md`.

---

## Task 1: bin/wt-metrics — scaffold + system + disk + `all`

**Files:** Create `bin/wt-metrics`, `tests/metrics.bats`

**Interfaces:**
- Produces: `wt-metrics system` → JSON `{mem_total_kb,mem_avail_kb,swap_total_kb,swap_used_kb,load1,ncpu,psi_cpu_some_avg10?}`; `wt-metrics disk` → JSON array of `{mount,size,used,avail,use_pct}`; `wt-metrics all` → `{system:…,disk:…,docker:…,worktrees:…,sessions:…}` (docker/worktrees/sessions added in Task 2, default to `[]` here).

- [ ] **Step 1: Write the failing test**

`tests/metrics.bats`:
```bash
load helpers
setup() { setup_wt; M="$WT_ROOT/bin/wt-metrics"; }
@test "system emits valid JSON with numeric mem/swap/ncpu" {
  run "$M" system
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("mem_total_kb") and has("swap_total_kb") and (.ncpu|type=="number")' >/dev/null
}
@test "disk emits a JSON array of mounts" {
  run "$M" disk
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type=="array" and (length>=1) and (.[0]|has("mount") and has("use_pct"))' >/dev/null
}
@test "all emits an object with the five sections" {
  run "$M" all
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("worktrees") and has("sessions")' >/dev/null
}
@test "unknown section fails" { run "$M" bogus; [ "$status" -ne 0 ]; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/metrics.bats` → FAIL.

- [ ] **Step 3: Write minimal implementation**

`bin/wt-metrics`:
```bash
#!/usr/bin/env bash
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_BIN="${WT_METRICS_WT:-$HERE/wt}"

m_system() {
  local mt ma st sf load ncpu
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null); ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null); sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null); ncpu=$(nproc 2>/dev/null || echo 0)
  local psi; psi=$(awk -F'[= ]' '/^some/{print $3}' /proc/pressure/cpu 2>/dev/null)
  jq -n --argjson mt "${mt:-0}" --argjson ma "${ma:-0}" --argjson st "${st:-0}" --argjson sf "${sf:-0}" \
        --argjson load "${load:-0}" --argjson ncpu "${ncpu:-0}" --arg psi "${psi:-}" \
    '{mem_total_kb:$mt,mem_avail_kb:$ma,swap_total_kb:$st,swap_used_kb:($st-$sf),load1:$load,ncpu:$ncpu,psi_cpu_some_avg10:($psi|tonumber?)}' 2>/dev/null || echo '{}'
}
m_disk() {
  df -P -k 2>/dev/null | awk 'NR>1{printf "%s\t%s\t%s\t%s\t%s\n",$6,$2,$3,$4,$5}' \
   | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{mount:.[0],size:(.[1]|tonumber?),used:(.[2]|tonumber?),avail:(.[3]|tonumber?),use_pct:.[4]})' 2>/dev/null || echo '[]'
}
m_docker() { echo '[]'; }      # Task 2
m_worktrees() { echo '[]'; }   # Task 2
m_sessions() { echo '[]'; }    # Task 2
m_all() {
  jq -n --argjson system "$(m_system)" --argjson disk "$(m_disk)" \
        --argjson docker "$(m_docker)" --argjson worktrees "$(m_worktrees)" --argjson sessions "$(m_sessions)" \
    '{system:$system,disk:$disk,docker:$docker,worktrees:$worktrees,sessions:$sessions}' 2>/dev/null || echo '{}'
}
case "${1:-}" in
  system) m_system;; disk) m_disk;; docker) m_docker;; worktrees) m_worktrees;; sessions) m_sessions;; all) m_all;;
  *) echo "usage: wt-metrics system|disk|docker|worktrees|sessions|all" >&2; exit 2;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/metrics.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-metrics tests/metrics.bats
git commit -m "feat(wt-dash): wt-metrics collectors — system, disk, all aggregator"
```

---

## Task 2: wt-metrics — docker + worktrees + sessions sections

**Files:** Modify `bin/wt-metrics`; Create `tests/metrics-docker-sessions.bats`

**Interfaces:**
- Produces (replaces the Task-1 stubs): `docker` → array of `{name,project,cpu_pct,mem_used,mem_pct}`; `worktrees` → `wt list --json` items enriched with `{disk_bytes}`; `sessions` → array of `{pid,kind,model,rss_kb,cpu_pct,etime_s}` for `claude`/`remote-control`/SDK backends.

- [ ] **Step 1: Write the failing test**

`tests/metrics-docker-sessions.bats`:
```bash
load helpers
setup() {
  setup_wt; M="$WT_ROOT/bin/wt-metrics"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  # stub docker: `docker stats --no-stream --format {{json .}}` then `docker ps` label lookup
  cat > "$BIN/docker" <<'EOF'
#!/bin/bash
case "$*" in
  *"stats"*) printf '%s\n' '{"Name":"myapp-t1-php-1","CPUPerc":"3.50%","MemUsage":"120MiB / 2GiB","MemPerc":"5.86%"}';;
  *"inspect"*) echo "myapp-t1";;   # compose project label
  *) echo "";;
esac
EOF
  chmod +x "$BIN/docker"
  # stub wt list --json
  cat > "$BIN/wt" <<'EOF'
#!/bin/bash
[ "$1" = list ] && echo '[{"app":"myapp","slug":"t1","project":"myapp-t1","path":"'"$HOME"'/wt/myapp-t1","domain":"myapp-t1.docker.test"}]'
EOF
  chmod +x "$BIN/wt"; mkdir -p "$HOME/wt/myapp-t1"
  export WT_METRICS_WT="$BIN/wt"; export PATH="$BIN:$PATH"
}
@test "docker section maps name+project+cpu+mem" {
  run "$M" docker
  echo "$output" | jq -e 'type=="array" and (.[0].name=="myapp-t1-php-1") and (.[0].cpu_pct=="3.50%")' >/dev/null
}
@test "worktrees section enriches wt list with disk_bytes" {
  run "$M" worktrees
  echo "$output" | jq -e '.[0].project=="myapp-t1" and (.[0]|has("disk_bytes"))' >/dev/null
}
@test "sessions section returns an array (may be empty in test env)" {
  run "$M" sessions
  echo "$output" | jq -e 'type=="array"' >/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/metrics-docker-sessions.bats` → FAIL (stubs still `[]`).

- [ ] **Step 3: Write minimal implementation**

Replace the three stubs in `bin/wt-metrics`:
```bash
m_docker() {
  docker stats --no-stream --format '{{json .}}' 2>/dev/null \
   | jq -s 'map({name:.Name, cpu_pct:.CPUPerc, mem_used:(.MemUsage|split(" / ")[0]), mem_pct:.MemPerc,
                 project:(.Name|capture("^(?<p>.+)-[^-]+-[0-9]+$").p // .Name)})' 2>/dev/null || echo '[]'
}
m_worktrees() {
  local list; list="$("$WT_BIN" list --json 2>/dev/null)"; [ -n "$list" ] || { echo '[]'; return; }
  printf '%s' "$list" | jq -c '.[]' 2>/dev/null | while read -r e; do
    local p db; p="$(printf '%s' "$e" | jq -r '.path // empty')"; db=0
    [ -n "$p" ] && [ -d "$p" ] && db="$(du -sb "$p" 2>/dev/null | awk '{print $1}')"
    printf '%s' "$e" | jq --argjson d "${db:-0}" '. + {disk_bytes:$d}'
  done | jq -s '.' 2>/dev/null || echo '[]'
}
m_sessions() {
  ps -eo pid=,rss=,pcpu=,etimes=,args= 2>/dev/null \
   | awk '/[c]laude|remote-control|versions\/.*--print/{
        kind="claude"; if($0 ~ /remote-control/) kind="remote-control"; else if($0 ~ /--print --sdk-url/) kind="sdk-backend";
        model=""; if(match($0,/--model [A-Za-z0-9_.:-]+\[?1?m?\]?/)) model=substr($0,RSTART+8,RLENGTH-8);
        printf "%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,kind"|"model }' \
   | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{pid:(.[0]|tonumber?),rss_kb:(.[1]|tonumber?),cpu_pct:(.[2]|tonumber?),etime_s:(.[3]|tonumber?),kind:(.[4]|split("|")[0]),model:(.[4]|split("|")[1])})' 2>/dev/null || echo '[]'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/metrics-docker-sessions.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-metrics tests/metrics-docker-sessions.bats
git commit -m "feat(wt-dash): wt-metrics docker/worktrees/sessions sections"
```

---

## Task 3: PHP backend — metrics + csv + static serving

**Files:** Create `dashboard/server/api.php`, `dashboard/server/router.php`, `tests/api.bats`

**Interfaces:**
- Produces: `wt_api_metrics()` → string JSON (runs `wt-metrics all`, ~2s file cache); `wt_api_csv()` → CSV; `router.php` dispatches `GET /api/metrics`, `GET /api/metrics.csv`, static files from `dashboard/public`.

- [ ] **Step 1: Write the failing test**

`tests/api.bats`:
```bash
load helpers
setup() {
  setup_wt
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/bin/bash\necho "{\\"system\\":{},\\"disk\\":[],\\"docker\\":[],\\"worktrees\\":[],\\"sessions\\":[]}"\n' > "$BIN/wt-metrics"; chmod +x "$BIN/wt-metrics"
  export WT_METRICS_BIN="$BIN/wt-metrics" WT_DASH_CACHE="$BATS_TEST_TMPDIR/cache.json"
  command -v php >/dev/null || skip "php not installed"
}
@test "metrics endpoint returns valid JSON with sections" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_metrics();'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("sessions")' >/dev/null
}
@test "csv endpoint returns CSV header" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/api.php"; echo wt_api_csv();'
  [[ "$output" == *","* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/api.bats` → FAIL.

- [ ] **Step 3: Write minimal implementation**

`dashboard/server/api.php`:
```php
<?php
function wt_metrics_bin(): string { return getenv('WT_METRICS_BIN') ?: dirname(__DIR__,2).'/bin/wt-metrics'; }
function wt_api_metrics(): string {
  $cache = getenv('WT_DASH_CACHE') ?: sys_get_temp_dir().'/wt-dash-metrics.json';
  if (is_file($cache) && (time() - filemtime($cache)) < 2) { $c = @file_get_contents($cache); if ($c) return $c; }
  $out = @shell_exec(escapeshellarg(wt_metrics_bin()).' all 2>/dev/null');
  if (!$out || json_decode($out) === null) { $out = '{"system":{},"disk":[],"docker":[],"worktrees":[],"sessions":[]}'; }
  @file_put_contents($cache, $out);
  return $out;
}
function wt_api_csv(): string {
  $m = json_decode(wt_api_metrics(), true) ?: [];
  $rows = [['section','key','value']];
  foreach (($m['system'] ?? []) as $k=>$v) $rows[] = ['system',$k,(string)$v];
  foreach (($m['sessions'] ?? []) as $s) $rows[] = ['session',($s['pid']??''),($s['kind']??'').' rss='.($s['rss_kb']??'')];
  $buf = fopen('php://temp','r+'); foreach ($rows as $r) fputcsv($buf,$r); rewind($buf);
  return stream_get_contents($buf);
}
```
`dashboard/server/router.php`:
```php
<?php
require __DIR__.'/api.php';
$uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($uri === '/api/metrics') { header('Content-Type: application/json'); echo wt_api_metrics(); return true; }
if ($uri === '/api/metrics.csv') { header('Content-Type: text/csv'); echo wt_api_csv(); return true; }
if (preg_match('#^/api/worktrees/([^/]+)/destroy$#', $uri, $m) && $_SERVER['REQUEST_METHOD']==='POST') {
  require __DIR__.'/destroy.php'; header('Content-Type: application/json'); echo wt_api_destroy($m[1]); return true; // Task 4
}
$pub = dirname(__DIR__).'/public';
$path = realpath($pub.($uri === '/' ? '/index.html' : $uri));
if ($path && str_starts_with($path, realpath($pub)) && is_file($path)) { return false; } // let php -S serve it
http_response_code(404); echo 'not found'; return true;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/api.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add dashboard/server/api.php dashboard/server/router.php tests/api.bats
git commit -m "feat(wt-dash): PHP backend metrics + csv + static router"
```

---

## Task 4: PHP backend — destroy endpoint (validated)

**Files:** Create `dashboard/server/destroy.php`; add tests to `tests/api.bats` (or `tests/api-destroy.bats`)

**Interfaces:**
- Produces: `wt_api_destroy(string $project): string` — validates `$project` exists in `wt list --json`; if not → JSON error (and sets 404); else runs `wt destroy <app> <slug> --yes` and returns `{ok,output}`.

- [ ] **Step 1: Write the failing test**

`tests/api-destroy.bats`:
```bash
load helpers
setup() {
  setup_wt
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/wt" <<'EOF'
#!/bin/bash
if [ "$1" = list ]; then echo '[{"app":"myapp","slug":"t1","project":"myapp-t1"}]'; exit 0; fi
if [ "$1" = destroy ]; then echo "destroyed $2 $3 $4"; exit 0; fi
EOF
  chmod +x "$BIN/wt"; export WT_DASH_WT="$BIN/wt"
  command -v php >/dev/null || skip "php not installed"
}
@test "destroy of a known project calls wt destroy" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/destroy.php"; echo wt_api_destroy("myapp-t1");'
  echo "$output" | jq -e '.ok==true' >/dev/null
  [[ "$output" == *"destroyed myapp t1 --yes"* ]]
}
@test "destroy of an unknown project is refused, no wt destroy" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/destroy.php"; echo wt_api_destroy("evil-proj");'
  echo "$output" | jq -e '.ok==false' >/dev/null
  [[ "$output" != *"destroyed"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/api-destroy.bats` → FAIL.

- [ ] **Step 3: Write minimal implementation**

`dashboard/server/destroy.php`:
```php
<?php
function wt_dash_wt(): string { return getenv('WT_DASH_WT') ?: dirname(__DIR__,2).'/bin/wt'; }
function wt_api_destroy(string $project): string {
  $wt = wt_dash_wt();
  $list = json_decode((string)@shell_exec(escapeshellarg($wt).' list --json 2>/dev/null'), true) ?: [];
  $match = null; foreach ($list as $e) { if (($e['project'] ?? null) === $project) { $match = $e; break; } }
  if (!$match) { http_response_code(404); return json_encode(['ok'=>false,'error'=>'unknown project']); }
  $cmd = escapeshellarg($wt).' destroy '.escapeshellarg($match['app']).' '.escapeshellarg($match['slug']).' --yes 2>&1';
  $out = (string)@shell_exec($cmd);
  return json_encode(['ok'=>true,'output'=>$out]);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/api-destroy.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add dashboard/server/destroy.php tests/api-destroy.bats
git commit -m "feat(wt-dash): validated destroy endpoint (registry-checked)"
```

---

## Task 5: Static frontend

**Files:** Create `dashboard/public/index.html`, `dashboard/public/style.css`, `dashboard/public/app.js`, `tests/frontend.bats`

**Interfaces:** none (static assets). Verification = files present + structural asserts + manual checklist.

- [ ] **Step 1: Write the failing test**

`tests/frontend.bats`:
```bash
load helpers
setup() { setup_wt; P="$WT_ROOT/dashboard/public"; }
@test "index.html loads app.js and style.css and has section containers" {
  [ -f "$P/index.html" ] && [ -f "$P/app.js" ] && [ -f "$P/style.css" ]
  grep -q 'app.js' "$P/index.html"; grep -q 'style.css' "$P/index.html"
  for id in system docker worktrees sessions disk; do grep -q "id=\"$id\"" "$P/index.html"; done
}
@test "app.js polls /api/metrics and wires destroy + export" {
  grep -q '/api/metrics' "$P/app.js"
  grep -q '/destroy' "$P/app.js"
  grep -q 'metrics.csv' "$P/app.js"
  grep -qi 'setInterval\|setTimeout' "$P/app.js"
}
@test "no external CDN dependency" {
  ! grep -qiE 'https?://[^"]+\.(js|css)' "$P/index.html"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/frontend.bats` → FAIL.

- [ ] **Step 3: Write the frontend**

- `index.html`: a titled page with five `<section id="system|docker|worktrees|sessions|disk">` containers, an export link, links `style.css` + `app.js` (relative, no CDN). Theme via `prefers-color-scheme`.
- `style.css`: CSS variables for light/dark; simple gauge/bar classes; responsive grid; a table style.
- `app.js`: `async function refresh()` → `fetch('/api/metrics')` → render each section (system gauges from mem/swap/load/ncpu; docker/worktrees/sessions/disk as tables); a small in-memory ring buffer per metric for CSS sparklines; `setInterval(refresh, 3000)`; each worktree row gets a "Supprimer" button → `confirm()` then `POST /api/worktrees/<project>/destroy` then refresh, and an "Ouvrir" link to `https://<domain>`; an "Export CSV" link to `/api/metrics.csv`. Escape all interpolated values (textContent, not innerHTML, for data).

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/frontend.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add dashboard/public tests/frontend.bats
git commit -m "feat(wt-dash): static observability frontend (poll, destroy, export)"
```

---

## Task 6: bin/wt-dash-install — systemd unit + Traefik route

**Files:** Create `bin/wt-dash-install`, `tests/dash-install.bats`

**Interfaces:**
- Produces: `wt-dash-install [--uninstall]` — writes/removes a `systemd --user` unit `${WT_DASH_UNIT_DIR:-$HOME/.config/systemd/user}/wt-dashboard.service` (runs `php -S <bind>:<port> -t dashboard/public dashboard/server/router.php`) and a Traefik file-provider entry in `${WT_DASH_TRAEFIK:-configuration/traefik2/config/dynamic_conf.local.yaml}`. Idempotent.

- [ ] **Step 1: Write the failing test**

`tests/dash-install.bats`:
```bash
load helpers
setup() {
  setup_wt
  export WT_DASH_UNIT_DIR="$BATS_TEST_TMPDIR/systemd" WT_DASH_TRAEFIK="$BATS_TEST_TMPDIR/dynamic.yaml" WT_DASH_RELOAD=true
  printf 'http:\n  routers: {}\n  services: {}\n' > "$WT_DASH_TRAEFIK"
}
@test "install writes a systemd unit running php -S with the router" {
  run "$WT_ROOT/bin/wt-dash-install"; [ "$status" -eq 0 ]
  grep -q 'php -S' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
  grep -q 'router.php' "$WT_DASH_UNIT_DIR/wt-dashboard.service"
}
@test "install adds a traefik router for worktree.docker.test idempotently" {
  "$WT_ROOT/bin/wt-dash-install"
  grep -q 'worktree.docker.test' "$WT_DASH_TRAEFIK"
  before="$(cat "$WT_DASH_TRAEFIK")"; "$WT_ROOT/bin/wt-dash-install"
  [ "$(cat "$WT_DASH_TRAEFIK")" = "$before" ]   # idempotent
}
@test "uninstall removes the unit and the traefik router" {
  "$WT_ROOT/bin/wt-dash-install"
  run "$WT_ROOT/bin/wt-dash-install" --uninstall; [ "$status" -eq 0 ]
  [ ! -f "$WT_DASH_UNIT_DIR/wt-dashboard.service" ]
  ! grep -q 'wt-dashboard' "$WT_DASH_TRAEFIK"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/dash-install.bats` → FAIL.

- [ ] **Step 3: Write minimal implementation**

`bin/wt-dash-install` (bash + a yaml edit done via a tiny python3 or `yq` if present, else a marker-block append). Use a marker-delimited block so idempotency is a simple strip-then-append on the YAML file:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
PORT="${WT_DASH_PORT:-8899}"; BIND="${WT_DASH_BIND:-0.0.0.0}"
UNIT_DIR="${WT_DASH_UNIT_DIR:-$HOME/.config/systemd/user}"; UNIT="$UNIT_DIR/wt-dashboard.service"
TRAEFIK="${WT_DASH_TRAEFIK:-$ROOT/configuration/traefik2/config/dynamic_conf.local.yaml}"
BEGIN="# >>> wt-dashboard >>>"; END="# <<< wt-dashboard <<<"
strip_block(){ awk -v b="$BEGIN" -v e="$END" 'BEGIN{k=1} $0==b{k=0} k{print} $0==e{k=1}' "$1"; }

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$UNIT"
  [ -f "$TRAEFIK" ] && { tmp=$(mktemp); strip_block "$TRAEFIK" > "$tmp" && mv "$tmp" "$TRAEFIK"; }
  command -v systemctl >/dev/null && systemctl --user daemon-reload 2>/dev/null || true
  echo "wt-dashboard uninstalled"; exit 0
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT" <<EOF
[Unit]
Description=wt dashboard
[Service]
ExecStart=/usr/bin/php -S ${BIND}:${PORT} -t ${ROOT}/dashboard/public ${ROOT}/dashboard/server/router.php
Restart=on-failure
[Install]
WantedBy=default.target
EOF

# Traefik file-provider block (marker-delimited, idempotent). basicauth users via WT_DASH_BASICAUTH (htpasswd line) if set.
tmp=$(mktemp); strip_block "$TRAEFIK" > "$tmp"
HOSTADDR="${WT_DASH_HOSTADDR:-100.75.44.109}"   # Tailscale IP of the host (Traefik reaches the host service here)
cat >> "$tmp" <<EOF
$BEGIN
http:
  routers:
    wt-dashboard:
      rule: "Host(\`worktree.docker.test\`)"
      entrypoints: [websecure]
      service: wt-dashboard
      middlewares: [wt-dashboard-auth]
      tls: {}
  services:
    wt-dashboard:
      loadBalancer:
        servers:
          - url: "http://${HOSTADDR}:${PORT}"
  middlewares:
    wt-dashboard-auth:
      basicAuth:
        users: ["${WT_DASH_BASICAUTH:-admin:\$apr1\$placeholder}"]
$END
EOF
mv "$tmp" "$TRAEFIK"

if [ "${WT_DASH_RELOAD:-}" != "true" ]; then
  command -v systemctl >/dev/null && { systemctl --user daemon-reload; systemctl --user enable --now wt-dashboard.service 2>/dev/null || true; }
fi
echo "wt-dashboard installed (port ${PORT}); confirm Traefik host address ${HOSTADDR} is reachable from the traefik container"
```
Note the plan's install task MUST, on the real host, confirm `HOSTADDR` (the address the Traefik container can use to reach this host service) — default is the Tailscale IP `100.75.44.109`; verify with `docker exec infra_traefik wget -qO- http://<addr>:<port>/api/metrics` (or curl) and adjust `WT_DASH_HOSTADDR` if needed. Also generate a real basicauth entry (`htpasswd`) rather than the placeholder.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/dash-install.bats` → PASS. Then `bats tests/` → green.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-dash-install tests/dash-install.bats
git commit -m "feat(wt-dash): installer — systemd user unit + Traefik file-provider route"
```

---

## Task 7: README + smoke + full suite + manual bring-up

**Files:** Create `docs/wt-dashboard-README.md`, `tests/dash-smoke.bats`

**Interfaces:** none (docs + green suite).

- [ ] **Step 1: Write the failing test**

`tests/dash-smoke.bats`:
```bash
load helpers
setup() { setup_wt; command -v php >/dev/null || skip "php not installed"; }
@test "wt-metrics all is valid JSON with all sections" {
  run "$WT_ROOT/bin/wt-metrics" all
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("docker") and has("worktrees") and has("sessions") and has("disk")' >/dev/null
}
@test "router serves index.html for /" {
  # boot php -S on an ephemeral port, curl /
  PORT=8912; php -S 127.0.0.1:$PORT -t "$WT_ROOT/dashboard/public" "$WT_ROOT/dashboard/server/router.php" >/dev/null 2>&1 &
  pid=$!; sleep 1
  run curl -s "http://127.0.0.1:$PORT/"; kill "$pid" 2>/dev/null
  [[ "$output" == *"<section id=\"system\""* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/dash-smoke.bats` (fails if wiring/serving is off).

- [ ] **Step 3: Write docs + fix wiring**

`docs/wt-dashboard-README.md` — cover: what it shows (system/docker/worktrees/sessions/disk) + safe actions (destroy worktree, open app); prerequisites (`php`, `jq`, docker); install (`bin/wt-dash-install`) / uninstall; the **manual bring-up** on the VPS:
```
bin/wt-dash-install                     # writes systemd unit + Traefik route
systemctl --user status wt-dashboard    # confirm running
# confirm Traefik reaches the host service, then open (Tailscale + basicauth):
#   https://worktree.docker.test
docker exec infra_traefik wget -qO- http://100.75.44.109:8899/api/metrics | head   # reachability check
bin/wt-dash-install --uninstall
```
Note the basicauth credential generation (`htpasswd`) and confirming `WT_DASH_HOSTADDR`.

- [ ] **Step 4: Run the whole suite**

Run: `bats tests/` → ALL PASS (SP1 + SP2 + SP3).

- [ ] **Step 5: Commit**

```bash
git add docs/wt-dashboard-README.md tests/dash-smoke.bats
git commit -m "docs(wt-dash): README + smoke; green suite"
```

---

## Self-Review

- **Spec coverage:** system/disk collectors (T1) ✓ · docker/worktrees/sessions collectors (T2) ✓ · metrics+csv API + static serving (T3) ✓ · validated destroy endpoint (T4) ✓ · frontend with poll/destroy/open/export (T5) ✓ · systemd unit + Traefik file-provider + basicauth install (T6) ✓ · README + smoke + reachability check (T7) ✓ · export (T3 csv + T5 button) ✓ · fail-safe collectors (T1/T2) ✓ · fixed-endpoints/registry-validated destroy, no arbitrary exec (T4) ✓.
- **Placeholder scan:** none — real bash/PHP/JS/bats. The one runtime unknown (Traefik→host address) is an explicit confirm-then-set step in T6/T7 with a default (Tailscale IP) and a concrete verification command, not a placeholder.
- **Type consistency:** collectors' JSON keys (`project`, `disk_bytes`, `pid/rss_kb/cpu_pct/etime_s/kind/model`, `mount/use_pct`, `mem_total_kb/swap_used_kb/ncpu`) are the same the frontend renders and the API passes through; `wt_api_destroy`/`wt_api_metrics`/`wt_api_csv` names match router.php's calls; env overrides (`WT_METRICS_WT`, `WT_METRICS_BIN`, `WT_DASH_WT`, `WT_DASH_CACHE`, `WT_DASH_PORT/BIND/UNIT_DIR/TRAEFIK/HOSTADDR/BASICAUTH/RELOAD`) are used consistently by tests and code.
- **Deferred (spec §6):** process/stack control from the UI (v2), metric historisation (v2).
