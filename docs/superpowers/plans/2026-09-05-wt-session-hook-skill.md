# wt — SessionStart hook + /worktree-env skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the `wt` engine into Claude Code's session lifecycle: a fail-safe `SessionStart` hook that DETECTS work-in-progress in a managed app repo and SUGGESTS a clean worktree, plus a `/worktree-env` skill that DRIVES `wt` create/list/open/destroy on explicit request.

**Architecture:** A pure-logic bash lib (`lib/hook.sh`) is unit-tested with `bats`; the hook entrypoint (`bin/wt-session-hook`) reads the SessionStart stdin JSON, calls the lib + `wt list --json`, emits `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":...}}`, and ALWAYS exits 0. An idempotent installer (`bin/wt-hook-install`) registers the hook in `~/.claude/settings.json` and links the skill source (`skills/worktree-env/SKILL.md`) into `~/.claude/skills/`.

**Tech Stack:** bash 5, `jq`, `git`, `bats-core`. Builds on the `wt` engine (SP1) present at `bin/wt` on this branch.

**Spec:** `Project/Infra/docs/2026-09-05-wt-session-hook-skill-design.md`

## Global Constraints

- bash only; deps `jq`, `git`. The hook is READ-ONLY, fast (<~1s), and MUST always `exit 0` (never exit 2 — that would block session start).
- SessionStart hook I/O contract (confirmed vs official docs): input = JSON on **stdin** with `.cwd`; output = JSON on **stdout** `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<text>"}}`. No output (empty stdout) or `{}` = no context injected.
- Managed repos = the 5 `repo_path`s in `etc/wt/apps.conf` (SP1). WIP = dirty tree (`git status --porcelain` non-empty) OR current branch != app base (develop; hotfix→main is create-time only, so the base to compare is `develop`).
- The hook calls `wt` by absolute path resolved relative to the hook script (`$(dirname hook)/wt`); never hard-code a machine path in committed code.
- No Claude/AI attribution anywhere in commits or files.

---

## File Structure

- `lib/hook.sh` — pure helpers: `wt_hook_app_for_cwd`, `wt_hook_is_wip`, `wt_hook_build_context`.
- `bin/wt-session-hook` — entrypoint: read stdin `.cwd` → resolve app → detect WIP → gather active envs → emit JSON → `exit 0`.
- `bin/wt-hook-install` — idempotent installer/uninstaller: settings.json hook block + skill symlink.
- `skills/worktree-env/SKILL.md` — the `/worktree-env` skill (create/list/open/destroy via `wt`).
- `tests/hook.bats`, `tests/hook-entrypoint.bats`, `tests/hook-install.bats` + reuse `tests/helpers.bash`.
- `docs/wt-hook-README.md` — install/usage + manual end-to-end.

---

## Task 1: lib/hook.sh — pure detection helpers

**Files:** Create `lib/hook.sh`, `tests/hook.bats`

**Interfaces:**
- Produces: `wt_hook_app_for_cwd <cwd> <apps_conf>` → prints `app<TAB>repo<TAB>base` for the managed repo containing cwd, else empty + non-zero. `wt_hook_is_wip <repo> <base>` → exit 0 if dirty OR current branch != base. `wt_hook_build_context <app> <branch> <nchanges> <envs_tsv>` → prints the suggestion text (empty if nothing to suggest).

- [ ] **Step 1: Write the failing test**

`tests/hook.bats`:
```bash
load helpers
setup() {
  setup_wt; source "$WT_ROOT/lib/hook.sh"
  CONF="$BATS_TEST_TMPDIR/apps.conf"
  printf 'myapp|%s|symfony|develop|.docker/docker-compose.yml|make install\n' "$BATS_TEST_TMPDIR/repos/myapp" > "$CONF"
  mkdir -p "$BATS_TEST_TMPDIR/repos/myapp/sub"
}
@test "app_for_cwd matches a managed repo (and subdir)" {
  run wt_hook_app_for_cwd "$BATS_TEST_TMPDIR/repos/myapp/sub" "$CONF"
  [ "$status" -eq 0 ]
  [[ "$output" == myapp$'\t'* ]]
  [[ "$output" == *$'\t'develop ]]
}
@test "app_for_cwd rejects an unmanaged dir" {
  run wt_hook_app_for_cwd "/tmp/somewhere-else" "$CONF"
  [ "$status" -ne 0 ]
}
@test "is_wip true when branch != base" {
  local r="$BATS_TEST_TMPDIR/gitrepo"; mkdir -p "$r"; ( cd "$r"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init; git checkout -q -b feature/x )
  run wt_hook_is_wip "$r" develop; [ "$status" -eq 0 ]
}
@test "is_wip false when clean on base" {
  local r="$BATS_TEST_TMPDIR/gitrepo2"; mkdir -p "$r"; ( cd "$r"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init )
  run wt_hook_is_wip "$r" develop; [ "$status" -ne 0 ]
}
@test "build_context empty when no wip and no envs" {
  run wt_hook_build_context myapp develop 0 ""
  [ -z "$output" ]
}
@test "build_context mentions app, branch, count when wip" {
  run wt_hook_build_context myapp feature/x 3 ""
  [[ "$output" == *"myapp"* ]]; [[ "$output" == *"feature/x"* ]]; [[ "$output" == *"3"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/hook.bats` → FAIL (functions undefined).

- [ ] **Step 3: Write minimal implementation**

`lib/hook.sh`:
```bash
# shellcheck shell=bash
wt_hook_app_for_cwd() { # cwd apps_conf -> "app\trepo\tbase" or non-zero
  local cwd="$1" conf="$2" app repo type base rest
  [ -f "$conf" ] || return 1
  # longest repo prefix wins
  local best_app="" best_repo="" best_base="" best_len=-1
  while IFS='|' read -r app repo type base rest; do
    [[ -z "$app" || "$app" == \#* ]] && continue
    case "$cwd/" in
      "$repo"/*) if [ "${#repo}" -gt "$best_len" ]; then best_len=${#repo}; best_app="$app"; best_repo="$repo"; best_base="$base"; fi;;
    esac
  done < "$conf"
  [ -n "$best_app" ] || return 1
  printf '%s\t%s\t%s' "$best_app" "$best_repo" "$best_base"
}
wt_hook_is_wip() { # repo base -> 0 if wip
  local repo="$1" base="$2" cur
  [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && return 0
  cur="$(git -C "$repo" branch --show-current 2>/dev/null)"
  [ -n "$cur" ] && [ "$cur" != "$base" ]
}
wt_hook_build_context() { # app branch nchanges envs_tsv
  local app="$1" branch="$2" n="$3" envs="$4"
  [ "$n" = 0 ] && [ "$branch" = "" ] && [ -z "$envs" ] && return 0
  # nothing to say if not wip and no envs
  if [ "$n" = 0 ] && [ -z "$branch" ] && [ -z "$envs" ]; then return 0; fi
  local out=""
  if [ -n "$branch" ]; then
    out="wt · ${app} : travail en cours (branche ${branch}, ${n} fichier(s) modifié(s)). "
    out+="Pour isoler un nouveau ticket : demande « nouveau worktree <TICKET> » (→ wt create)."
  fi
  if [ -n "$envs" ]; then
    out+=$'\n'"Envs actifs : ${envs}"
  fi
  printf '%s' "$out"
}
```
Note: the entrypoint (Task 2) decides WIP and passes `branch=""` when not WIP so `build_context` stays silent.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/hook.bats` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/hook.sh tests/hook.bats
git commit -m "feat(wt-hook): pure detection helpers (app-for-cwd, wip, context)"
```

---

## Task 2: bin/wt-session-hook — entrypoint (fail-safe)

**Files:** Create `bin/wt-session-hook`, `tests/hook-entrypoint.bats`

**Interfaces:**
- Consumes: `lib/hook.sh`, `etc/wt/apps.conf`, `bin/wt` (for `list --json`).
- Produces: an executable reading SessionStart stdin JSON and printing the hook JSON; ALWAYS exit 0.

- [ ] **Step 1: Write the failing test**

`tests/hook-entrypoint.bats`:
```bash
load helpers
setup() {
  setup_wt
  HOOK="$WT_ROOT/bin/wt-session-hook"
  # fake managed repo on a feature branch (wip)
  REPO="$BATS_TEST_TMPDIR/repos/myapp"; mkdir -p "$REPO"; ( cd "$REPO"
    git init -q -b develop; git config user.email t@t; git config user.name t
    echo a>a; git add a; git commit -qm init; git checkout -q -b feature/x )
  export WT_HOOK_APPS="$BATS_TEST_TMPDIR/apps.conf"
  printf 'myapp|%s|symfony|develop|.docker/docker-compose.yml|make install\n' "$REPO" > "$WT_HOOK_APPS"
  # stub `wt` on PATH returning an empty env list
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"; printf '#!/bin/bash\necho "[]"\n' > "$BIN/wt"; chmod +x "$BIN/wt"
  export WT_HOOK_WT="$BIN/wt"
}
@test "emits additionalContext for a wip managed repo" {
  run bash -c 'printf "{\"cwd\":\"%s\"}" "'"$REPO"'" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("feature/x")' >/dev/null
}
@test "silent (no additionalContext) for an unmanaged cwd" {
  run bash -c 'printf "{\"cwd\":\"/tmp/nope-%s\"}" "$$" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
  # either empty stdout or JSON without additionalContext
  if [ -n "$output" ]; then echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") == ""' >/dev/null; fi
}
@test "never fails even if wt/git blow up (fail-safe exit 0)" {
  export WT_HOOK_WT="/definitely/not/a/binary"
  run bash -c 'printf "{\"cwd\":\"%s\"}" "'"$REPO"'" | "'"$HOOK"'"'
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/hook-entrypoint.bats` → FAIL (hook missing).

- [ ] **Step 3: Write minimal implementation**

`bin/wt-session-hook`:
```bash
#!/usr/bin/env bash
# SessionStart hook: detect WIP in a managed wt repo and SUGGEST a worktree.
# Read-only, fail-safe: ALWAYS exit 0, never exit 2.
set +e
emit() { printf '%s' "$1"; exit 0; }   # $1 = JSON (or empty)
{
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$HERE/../lib/hook.sh" 2>/dev/null || emit ""
  CONF="${WT_HOOK_APPS:-$HERE/../etc/wt/apps.conf}"
  WT_BIN="${WT_HOOK_WT:-$HERE/wt}"

  IN="$(cat 2>/dev/null)"
  CWD="$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$CWD" ] || emit ""

  INFO="$(wt_hook_app_for_cwd "$CWD" "$CONF")" || emit ""
  APP="$(printf '%s' "$INFO" | cut -f1)"
  REPO="$(printf '%s' "$INFO" | cut -f2)"
  BASE="$(printf '%s' "$INFO" | cut -f3)"

  BRANCH=""; NCH=0
  if wt_hook_is_wip "$REPO" "$BASE"; then
    BRANCH="$(git -C "$REPO" branch --show-current 2>/dev/null)"
    NCH="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -c . )"
  fi

  ENVS="$("$WT_BIN" list --json 2>/dev/null | jq -r --arg a "$APP" \
    '[.[] | select(.app==$a) | "\(.project) → https://\(.domain)"] | join(" · ")' 2>/dev/null || echo "")"

  CTX="$(wt_hook_build_context "$APP" "$BRANCH" "$NCH" "$ENVS")"
  [ -n "$CTX" ] || emit ""
  OUT="$(jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null)"
  emit "$OUT"
} 2>/dev/null
emit ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/hook-entrypoint.bats` → PASS. Then `bats tests/` → all green.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-session-hook tests/hook-entrypoint.bats
git commit -m "feat(wt-hook): fail-safe SessionStart entrypoint emitting additionalContext"
```

---

## Task 3: bin/wt-hook-install — settings.json registration + skill link

**Files:** Create `bin/wt-hook-install`, `tests/hook-install.bats`

**Interfaces:**
- Produces: `wt-hook-install [--uninstall]` operating on `${WT_SETTINGS:-$HOME/.claude/settings.json}` and `${WT_SKILLS_DIR:-$HOME/.claude/skills}`. Idempotent add/remove of the SessionStart hook block; symlink of the skill source.

- [ ] **Step 1: Write the failing test**

`tests/hook-install.bats`:
```bash
load helpers
setup() {
  setup_wt
  export WT_SETTINGS="$BATS_TEST_TMPDIR/settings.json"
  export WT_SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
  echo '{}' > "$WT_SETTINGS"
}
@test "install adds a SessionStart command hook idempotently" {
  run "$WT_ROOT/bin/wt-hook-install"; [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart[0].hooks[0].type == "command"' "$WT_SETTINGS" >/dev/null
  jq -e '.hooks.SessionStart[0].hooks[0].command | test("wt-session-hook")' "$WT_SETTINGS" >/dev/null
  before="$(jq -S . "$WT_SETTINGS")"
  "$WT_ROOT/bin/wt-hook-install"   # second run
  [ "$(jq -S . "$WT_SETTINGS")" = "$before" ]   # no duplicate
  [ -L "$WT_SKILLS_DIR/worktree-env" ] || [ -e "$WT_SKILLS_DIR/worktree-env" ]
}
@test "uninstall removes the hook entry" {
  "$WT_ROOT/bin/wt-hook-install"
  run "$WT_ROOT/bin/wt-hook-install" --uninstall; [ "$status" -eq 0 ]
  jq -e '(.hooks.SessionStart // []) | map(.hooks[].command | test("wt-session-hook")) | any | not' "$WT_SETTINGS" >/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/hook-install.bats` → FAIL.

- [ ] **Step 3: Write minimal implementation**

`bin/wt-hook-install`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/wt-session-hook"
SETTINGS="${WT_SETTINGS:-$HOME/.claude/settings.json}"
SKILLS_DIR="${WT_SKILLS_DIR:-$HOME/.claude/skills}"
SKILL_SRC="$HERE/../skills/worktree-env"
mkdir -p "$(dirname "$SETTINGS")" "$SKILLS_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

remove_entry() { jq --arg h "$HOOK" '
  (.hooks.SessionStart) |= ( (. // [])
    | map( .hooks |= map(select(.command != $h)) )
    | map(select((.hooks|length) > 0)) )
  | if (.hooks.SessionStart|length)==0 then del(.hooks.SessionStart) else . end
' "$SETTINGS"; }

if [ "${1:-}" = "--uninstall" ]; then
  tmp="$(mktemp)"; remove_entry > "$tmp" && mv "$tmp" "$SETTINGS"
  [ -L "$SKILLS_DIR/worktree-env" ] && rm -f "$SKILLS_DIR/worktree-env" || true
  echo "wt hook uninstalled"; exit 0
fi

# add (idempotent: strip any existing entry for this hook, then append one)
tmp="$(mktemp)"
remove_entry | jq --arg h "$HOOK" '
  .hooks = (.hooks // {})
  | .hooks.SessionStart = ((.hooks.SessionStart // []) + [{matcher:"*",hooks:[{type:"command",command:$h,timeout:10}]}])
' > "$tmp" && mv "$tmp" "$SETTINGS"
# link skill source
[ -e "$SKILLS_DIR/worktree-env" ] || ln -s "$SKILL_SRC" "$SKILLS_DIR/worktree-env"
echo "wt hook installed → $SETTINGS"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/hook-install.bats` → PASS. Then `bats tests/` → all green.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-hook-install tests/hook-install.bats
git commit -m "feat(wt-hook): idempotent installer for settings.json hook + skill link"
```

---

## Task 4: skills/worktree-env/SKILL.md — the driver skill

**Files:** Create `skills/worktree-env/SKILL.md`

**Interfaces:** none (instructions). Verification = file present + valid frontmatter + a documented dry-run.

- [ ] **Step 1: Write the failing test**

`tests/skill.bats`:
```bash
load helpers
setup() { setup_wt; SK="$WT_ROOT/skills/worktree-env/SKILL.md"; }
@test "skill file exists with name+description frontmatter" {
  [ -f "$SK" ]
  head -6 "$SK" | grep -q '^name:'
  head -6 "$SK" | grep -q '^description:'
  grep -q 'wt create' "$SK"
  grep -q 'wt destroy' "$SK"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/skill.bats` → FAIL (file missing).

- [ ] **Step 3: Write the skill**

`skills/worktree-env/SKILL.md` — frontmatter (`name: worktree-env`, `description:` naming the triggers: "nouveau worktree", "on démarre <TICKET>", "liste/supprime mes worktrees") then a body instructing:
- Resolve the current repo → app via `etc/wt/apps.conf` (match cwd prefix). If not a managed repo, say so and stop.
- **create**: derive `feature` (default) or `hotfix` from the ticket/context; slug from the ticket key; run `wt create <app> <slug> --feature|--hotfix --ticket <KEY>`; on any doubt run `--dry-run` first and show the plan; then report the URL + path.
- **list**: run `wt list`.
- **open**: run `wt open <app> <slug>` and hand back the path.
- **destroy**: DESTRUCTIVE — show `wt destroy <app> <slug> --dry-run` first, get explicit confirmation, then run without `--dry-run`.
- Always call `wt` by the path in `Infra/bin/wt`; never fabricate env names — read them from `wt list`.
No Claude/AI attribution in the file.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/skill.bats` → PASS. Then `bats tests/` → all green.

- [ ] **Step 5: Commit**

```bash
git add skills/worktree-env/SKILL.md tests/skill.bats
git commit -m "feat(wt-hook): /worktree-env driver skill"
```

---

## Task 5: README + full suite + manual end-to-end

**Files:** Create `docs/wt-hook-README.md`; add `tests/hook-smoke.bats`.

**Interfaces:** none (docs + green suite).

- [ ] **Step 1: Write the failing test**

`tests/hook-smoke.bats` — end-to-end of the hook against a real managed repo fixture with a stubbed `wt` (reuses the entrypoint setup), asserting valid JSON out and exit 0 for both wip and non-wip cwd. (If the entrypoint wiring is off, this fails.)
```bash
load helpers
@test "hook output is always valid JSON or empty, exit 0" {
  setup_wt
  out="$(printf '{"cwd":"/tmp/none-%s"}' "$$" | "$WT_ROOT/bin/wt-session-hook"; echo "rc=$?")"
  [[ "$out" == *"rc=0" ]]
  body="${out%rc=*}"
  [ -z "$body" ] || echo "$body" | jq -e . >/dev/null
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/hook-smoke.bats` (fails if wiring/JSON is wrong).

- [ ] **Step 3: Write docs + fix any wiring**

`docs/wt-hook-README.md` — cover: what the hook does (detect+suggest, never auto-creates), install (`bin/wt-hook-install`) / uninstall (`--uninstall`), how the `/worktree-env` skill is used ("nouveau worktree GEL-123"), and a **manual end-to-end**:
```
# In a managed repo on a feature branch with changes, open a Claude session:
#   → the SessionStart hook injects a "travail en cours … nouveau worktree" suggestion.
# Ask: "nouveau worktree GEL-123"  → skill runs `wt create … --dry-run` then for real.
# Ask: "liste mes worktrees"       → `wt list`.
# Ask: "supprime le worktree …"    → `wt destroy … --dry-run` then confirm.
bin/wt-hook-install            # register; open a NEW session to load it
bin/wt-hook-install --uninstall
```

- [ ] **Step 4: Run the whole suite**

Run: `bats tests/` → ALL PASS (SP1 tests + SP2 tests).

- [ ] **Step 5: Commit**

```bash
git add docs/wt-hook-README.md tests/hook-smoke.bats
git commit -m "docs(wt-hook): README + smoke; green suite"
```

---

## Self-Review

- **Spec coverage:** hook detect+suggest (Tasks 1-2) ✓ · managed-repo scope + WIP=dirty-or-branch≠base (Task 1) ✓ · fail-safe exit 0 + SessionStart JSON contract (Task 2) ✓ · active-envs surfaced via `wt list --json` (Task 2) ✓ · settings.json registration + skill link (Task 3) ✓ · `/worktree-env` create/list/open/destroy with confirm-before-destroy (Task 4) ✓ · README + manual e2e (Task 5) ✓.
- **Placeholder scan:** none — real bash/bats/JSON throughout; the SessionStart contract is the confirmed one (stdin `.cwd`, stdout `hookSpecificOutput.additionalContext`, exit 0).
- **Type consistency:** `wt_hook_app_for_cwd` emits `app\trepo\tbase` consumed by the entrypoint via `cut -f1..3`; `wt_hook_build_context` args (app, branch, nchanges, envs) match the entrypoint's call; installer env-var overrides (`WT_SETTINGS`, `WT_SKILLS_DIR`, `WT_HOOK_APPS`, `WT_HOOK_WT`) are used consistently by tests and code.
- **Deferred (spec §9):** PrestaShop apps (v2), the dashboard (SP3).
