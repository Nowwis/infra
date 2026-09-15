# Lot 1 — Démontage de `wt` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supprimer entièrement l'outillage worktrees (`wt`) du VPS et du repo Infra sans perdre aucun travail, en gardant le dashboard fonctionnel jusqu'au lot 3.

**Architecture:** Un script one-shot `bin/wt-decommission` inventorie tout ce qui relève des worktrees (registre `wt`, worktrees git secondaires de tous les repos, `~/wt`, `.worktreeinclude`, hook/skill Claude), refuse d'agir tant qu'un élément porte du travail non sauvegardé, puis retire le tout en réutilisant `wt destroy` et `wt-hook-install --uninstall`. Après exécution réelle sur le VPS, le code `wt` est supprimé du repo et le dashboard est amputé de sa section worktrees.

**Tech Stack:** bash 5, git, jq, bats 1.10, PHP 8.3 (dashboard existant).

**Spec:** `docs/2026-09-15-work-console-design.md` §3 (lot 1).

## Global Constraints

- Travail dans le checkout principal `/home/webadmin/Project/Infra`, sur la branche `chore/decommission-wt` créée depuis `docs/work-console-spec` — aucun worktree.
- Messages de commit en anglais ; **aucune mention de Claude / IA, aucun trailer `Co-Authored-By`**.
- Aucun `git push`, aucune PR, aucune action sur le VPS réel (Task 3) sans **validation explicite de Simon**.
- Ne jamais `git add -A` / `git commit -a` : `configuration/traefik2/config/dynamic_conf.local.yaml` porte une modification runtime non commitée (route NOWIA) qui doit rester hors des commits.
- Les tests ne touchent jamais le vrai `$HOME` : toujours `setup_wt` (tests/helpers.bash), qui redirige `HOME` et `WT_STATE` vers `$BATS_TEST_TMPDIR`.
- Référence avant travaux : `bats tests/` → `1..89`, aucun `not ok`. Chaque tâche se termine suite complète verte.

---

### Task 1: `bin/wt-decommission` — inventaire et simulation

**Files:**
- Create: `bin/wt-decommission`
- Test: `tests/decommission.bats`

**Interfaces:**
- Produces (utilisé par Task 2) : fonctions shell `repos`, `secondary_worktrees <repo>`, `live_cwds`, `worktree_status <path> <prunable>`, `hook_present`, `inventory` ; variables globales `WORKTREES` (tableau `"repo<TAB>path<TAB>CODE"`), `BLOCKERS` (entier) ; variables de config `ROOT`, `STATE`, `WT_BIN`, `HOOK_INSTALL`, `SESSIONS_DIR`, `SETTINGS`, `SKILL_LINK`, `WT_DIR`.
- Surcharges d'environnement (tests) : `WT_DECOM_ROOT`, `WT_STATE`, `WT_DECOM_WT_BIN`, `WT_DECOM_HOOK_INSTALL`, `WT_DECOM_SESSIONS_DIR`, `WT_SETTINGS`, `WT_SKILLS_DIR`.
- Codes de statut : `SAUF`, `RISQUE` (affiché « À RISQUE »), `USAGE` (« EN USAGE »), `MANQUANT` ; dossier inconnu sous `~/wt` affiché « INCONNU ».

- [ ] **Step 0: Créer la branche de travail**

```bash
cd /home/webadmin/Project/Infra
git switch docs/work-console-spec
git branch chore/decommission-wt docs/work-console-spec
git switch chore/decommission-wt
```
(`git branch` + `git switch` plutôt que `checkout -b` : le hook `guard-branch-clean` bloque `-b` à cause de la modification Traefik non commitée, qui n'a rien à voir et ne sera pas commitée.)

- [ ] **Step 1: Write the failing tests**

Create `tests/decommission.bats` :

```bash
load helpers

setup() {
  setup_wt
  export WT_DECOM_ROOT="$BATS_TEST_TMPDIR/Project"
  export WT_DECOM_SESSIONS_DIR="$HOME/.claude/sessions"
  export WT_SETTINGS="$HOME/.claude/settings.json"
  export WT_SKILLS_DIR="$HOME/.claude/skills"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  mkdir -p "$WT_DECOM_ROOT" "$WT_DECOM_SESSIONS_DIR" "$WT_SKILLS_DIR" "$HOME/wt"
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  # wt destroy simulé : journalise l'appel, retire le worktree et l'entrée de registre
  cat > "$STUBS/wt" <<'EOF'
#!/usr/bin/env bash
echo "wt $*" >> "$CALLS"
if [ "$1" = destroy ]; then
  p="$HOME/wt/$2-$3"
  r="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir)"
  git -C "${r%/.git}" worktree remove --force "$p"
  jq --arg p "$2-$3" 'map(select(.project != $p))' "$WT_STATE/registry.json" > "$WT_STATE/r.tmp" \
    && mv "$WT_STATE/r.tmp" "$WT_STATE/registry.json"
fi
EOF
  cat > "$STUBS/wt-hook-install" <<'EOF'
#!/usr/bin/env bash
echo "hook-install $*" >> "$CALLS"
EOF
  chmod +x "$STUBS/wt" "$STUBS/wt-hook-install"
  export WT_DECOM_WT_BIN="$STUBS/wt" WT_DECOM_HOOK_INSTALL="$STUBS/wt-hook-install"
  D="$WT_ROOT/bin/wt-decommission"
}

# make_repo <org/name> : checkout principal avec un remote nu et main poussée
make_repo() {
  local repo="$WT_DECOM_ROOT/$1" remote="$BATS_TEST_TMPDIR/remotes/$1.git"
  mkdir -p "$(dirname "$repo")" "$(dirname "$remote")"
  git init -q --bare "$remote"
  git init -q -b main "$repo"
  git -C "$repo" remote add origin "$remote"
  echo base > "$repo/README"
  git -C "$repo" add README
  git -C "$repo" commit -qm init
  git -C "$repo" push -q -u origin main
}

# add_wt <org/name> <chemin> <branche> : worktree secondaire, branche poussée
add_wt() {
  git -C "$WT_DECOM_ROOT/$1" worktree add -q -b "$3" "$2" main
  git -C "$2" push -q -u origin "$3"
}

@test "dry-run classe SAUF, À RISQUE et MANQUANT sans rien modifier" {
  make_repo Org/app
  add_wt Org/app "$HOME/wt/app-clean" feature/clean
  add_wt Org/app "$HOME/wt/app-dirty" feature/dirty
  echo x > "$HOME/wt/app-dirty/new.txt"
  add_wt Org/app "$BATS_TEST_TMPDIR/gone" feature/gone
  rm -rf "$BATS_TEST_TMPDIR/gone"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  SAUF +.*/wt/app-clean '
  echo "$output" | grep -qE '^  À RISQUE +.*/wt/app-dirty .*1 fichier'
  echo "$output" | grep -qE '^  MANQUANT +.*/gone '
  echo "$output" | grep -q 'BLOQUANT : 1'
  echo "$output" | grep -q 'Simulation'
  [ -d "$HOME/wt/app-clean" ] && [ -d "$HOME/wt/app-dirty" ]
  [ ! -s "$CALLS" ]
}

@test "un commit jamais poussé rend le worktree À RISQUE" {
  make_repo Org/app
  add_wt Org/app "$HOME/wt/app-ahead" feature/ahead
  echo y > "$HOME/wt/app-ahead/f"
  git -C "$HOME/wt/app-ahead" add f
  git -C "$HOME/wt/app-ahead" commit -qm local

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  À RISQUE +.*/wt/app-ahead .*1 commit'
}

@test "un worktree où tourne une session Claude vivante est EN USAGE ; une session morte est ignorée" {
  make_repo Org/app
  local bridge="$WT_DECOM_ROOT/Org/app/.claude/worktrees/bridge-x"
  add_wt Org/app "$bridge" hotfix/x
  add_wt Org/app "$HOME/wt/app-dead" feature/dead
  jq -n --argjson pid "$$" --arg cwd "$bridge" '{pid:$pid,cwd:$cwd}' > "$WT_DECOM_SESSIONS_DIR/live.json"
  jq -n --arg cwd "$HOME/wt/app-dead" '{pid:2147483646,cwd:$cwd}' > "$WT_DECOM_SESSIONS_DIR/dead.json"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  EN USAGE +.*bridge-x '
  echo "$output" | grep -qE '^  SAUF +.*/wt/app-dead '
}

@test "un dossier sous ~/wt qui n'est pas un worktree est INCONNU et bloquant" {
  mkdir -p "$HOME/wt/stray"; touch "$HOME/wt/stray/f"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^  INCONNU +.*/wt/stray'
  echo "$output" | grep -q 'BLOQUANT : 1'
}

@test "l'inventaire signale registre, .worktreeinclude et configuration Claude" {
  make_repo Org/app
  mkdir -p "$WT_STATE"
  jq -n '[{project:"myapp-t1",app:"myapp",slug:"t1",path:"/x"}]' > "$WT_STATE/registry.json"
  printf '.mcp.json\n' > "$WT_DECOM_ROOT/Org/app/.worktreeinclude"
  echo '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/x/bin/wt-session-hook"}]}]}}' > "$WT_SETTINGS"
  ln -s /nonexistent "$WT_SKILLS_DIR/worktree-env"

  run "$D"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'myapp-t1'
  echo "$output" | grep -qE 'à supprimer +.*Org/app/.worktreeinclude'
  echo "$output" | grep -q 'hook SessionStart wt-session-hook : présent'
  echo "$output" | grep -q 'skill worktree-env : présent'
}

@test "option inconnue refusée" {
  run "$D" --bogus
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/decommission.bats`
Expected: FAIL (6 `not ok`), `bin/wt-decommission: No such file or directory`.

- [ ] **Step 3: Write the implementation**

Create `bin/wt-decommission` :

```bash
#!/usr/bin/env bash
# wt-decommission — démontage one-shot des worktrees (docs/2026-09-15-work-console-design.md §3.2).
# Simulation par défaut. Ne supprime rien tant qu'un élément porte du travail non sauvegardé.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${WT_DECOM_ROOT:-$HOME/Project}"
STATE="${WT_STATE:-$HOME/.local/state/wt}"
WT_BIN="${WT_DECOM_WT_BIN:-$HERE/wt}"
HOOK_INSTALL="${WT_DECOM_HOOK_INSTALL:-$HERE/wt-hook-install}"
SESSIONS_DIR="${WT_DECOM_SESSIONS_DIR:-$HOME/.claude/sessions}"
SETTINGS="${WT_SETTINGS:-$HOME/.claude/settings.json}"
SKILL_LINK="${WT_SKILLS_DIR:-$HOME/.claude/skills}/worktree-env"
WT_DIR="$HOME/wt"

die() { printf 'erreur : %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# Checkouts principaux : ROOT/<x> et ROOT/<x>/<y> dont .git est un dossier.
repos() {
  local g
  for g in "$ROOT"/*/.git "$ROOT"/*/*/.git; do
    [ -d "$g" ] && printf '%s\n' "${g%/.git}"
  done
}

# Worktrees secondaires d'un repo : "chemin<TAB>prunable(0|1)".
secondary_worktrees() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    /^worktree / { if (n++) print p "\t" pr; p = substr($0, 10); pr = 0 }
    /^prunable/  { pr = 1 }
    END          { if (n) print p "\t" pr }' | tail -n +2
}

# Répertoires de travail des sessions Claude dont le pid est vivant.
live_cwds() {
  local f pid
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && jq -r '.cwd // empty' "$f"
  done
}

# "CODE<TAB>détail" avec CODE ∈ SAUF, RISQUE, USAGE, MANQUANT.
worktree_status() { # path prunable
  local p="$1" pr="$2" cwd dirty ahead why=""
  if [ "$pr" = 1 ] || [ ! -d "$p" ]; then printf 'MANQUANT\t'; return; fi
  while IFS= read -r cwd; do
    case "$cwd/" in "$p"/*) printf 'USAGE\tsession Claude vivante dans ce dossier'; return ;; esac
  done < <(live_cwds)
  dirty="$(git -C "$p" status --porcelain 2>/dev/null | grep -c .)"
  ahead="$(git -C "$p" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
  [ "$dirty" -gt 0 ] && why="$dirty fichier(s) modifié(s)"
  [ "$ahead" -gt 0 ] && why="${why:+$why, }$ahead commit(s) non poussé(s)"
  if [ -n "$why" ]; then printf 'RISQUE\t%s' "$why"; else printf 'SAUF\t'; fi
}

label() {
  case "$1" in
    SAUF) echo 'SAUF' ;; RISQUE) echo 'À RISQUE' ;; USAGE) echo 'EN USAGE' ;; MANQUANT) echo 'MANQUANT' ;;
  esac
}

hook_present() {
  [ -f "$SETTINGS" ] && jq -e '[.hooks.SessionStart[]?.hooks[]?.command // empty] | any(test("wt-session-hook"))' \
    "$SETTINGS" >/dev/null 2>&1
}

WORKTREES=()
BLOCKERS=0

inventory() {
  local repo path pr st code why br d w known
  say "== Worktrees secondaires"
  while IFS= read -r repo; do
    while IFS=$'\t' read -r path pr; do
      [ -n "$path" ] || continue
      st="$(worktree_status "$path" "$pr")"
      code="${st%%$'\t'*}"; why="${st#*$'\t'}"
      br="$(git -C "$path" branch --show-current 2>/dev/null)"
      WORKTREES+=("$repo"$'\t'"$path"$'\t'"$code")
      case "$code" in RISQUE|USAGE) BLOCKERS=$((BLOCKERS + 1)) ;; esac
      printf '  %-9s %s (%s)%s\n' "$(label "$code")" "$path" "${br:-?}" "${why:+ : $why}"
    done < <(secondary_worktrees "$repo")
  done < <(repos)
  [ "${#WORKTREES[@]}" -gt 0 ] || say "  (aucun)"

  say "== Environnements wt (registre)"
  if [ -f "$STATE/registry.json" ] && [ "$(jq 'length' "$STATE/registry.json")" -gt 0 ]; then
    jq -r '.[] | "  \(.project)  \(.path)"' "$STATE/registry.json"
  else
    say "  (aucun)"
  fi

  say "== Dossiers sous ~/wt"
  if [ -d "$WT_DIR" ]; then
    for d in "$WT_DIR"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"; known=0
      for w in "${WORKTREES[@]}"; do [ "$(cut -f2 <<<"$w")" = "$d" ] && known=1; done
      if [ "$known" = 1 ]; then
        say "  worktree  $d"
      else
        say "  INCONNU   $d (pas un worktree : à traiter à la main)"
        BLOCKERS=$((BLOCKERS + 1))
      fi
    done
  fi

  say "== Fichiers .worktreeinclude"
  while IFS= read -r repo; do
    [ -f "$repo/.worktreeinclude" ] || continue
    if git -C "$repo" ls-files --error-unmatch .worktreeinclude >/dev/null 2>&1; then
      say "  versionné (laissé)  $repo/.worktreeinclude"
    else
      say "  à supprimer         $repo/.worktreeinclude"
    fi
  done < <(repos)

  say "== Configuration Claude"
  say "  hook SessionStart wt-session-hook : $(hook_present && echo présent || echo absent)"
  say "  skill worktree-env : $({ [ -L "$SKILL_LINK" ] || [ -e "$SKILL_LINK" ]; } && echo présent || echo absent)"
}

case "${1:-}" in
  "") ;;
  -h|--help) say "usage: wt-decommission [--apply]"; exit 0 ;;
  *) die "option inconnue : $1" ;;
esac
command -v jq >/dev/null || die "jq requis"

inventory
say ""
[ "$BLOCKERS" -gt 0 ] && say "BLOQUANT : $BLOCKERS élément(s) — --apply refusera tant qu'ils ne sont pas traités."
say "Simulation : rien n'a été modifié. Relancer avec --apply pour exécuter."
```

Then: `chmod +x bin/wt-decommission`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/decommission.bats`
Expected: `1..6`, 6 `ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-decommission tests/decommission.bats
git commit -m "feat(wt): add decommission inventory with dry-run safety report"
```

---

### Task 2: `bin/wt-decommission --apply`

**Files:**
- Modify: `bin/wt-decommission` (bloc final `case … say "Simulation…"`)
- Test: `tests/decommission.bats` (ajouts en fin de fichier)

**Interfaces:**
- Consumes (Task 1) : `repos`, `secondary_worktrees`, `hook_present`, `inventory`, `BLOCKERS`, `STATE`, `WT_BIN`, `HOOK_INSTALL`, `SETTINGS`, `WT_DIR`, `say`, `die`.
- Produces : fonction `apply` ; contrat CLI final `wt-decommission [--apply]` — exit 0 succès/simulation, exit 1 refus ou échec d'étape (message sur stderr).
- Contrat des outils appelés : `"$WT_BIN" destroy <app> <slug> --yes` ; `"$HOOK_INSTALL" --uninstall`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/decommission.bats` :

```bash
@test "--apply refuse tout si un worktree est À RISQUE" {
  make_repo Org/app
  add_wt Org/app "$HOME/wt/app-dirty" feature/dirty
  echo x > "$HOME/wt/app-dirty/n"
  mkdir -p "$WT_STATE"
  jq -n --arg p "$HOME/wt/app-dirty" '[{project:"app-dirty",app:"app",slug:"dirty",path:$p}]' > "$WT_STATE/registry.json"

  run "$D" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusé"* ]]
  [ -d "$HOME/wt/app-dirty" ]
  [ -f "$WT_STATE/registry.json" ]
  [ ! -s "$CALLS" ]
}

@test "--apply refuse tout si ~/wt contient un dossier INCONNU" {
  make_repo Org/app
  add_wt Org/app "$WT_DECOM_ROOT/Org/app/.claude/worktrees/bridge-x" hotfix/x
  mkdir -p "$HOME/wt/stray"; touch "$HOME/wt/stray/f"

  run "$D" --apply
  [ "$status" -eq 1 ]
  [ -d "$WT_DECOM_ROOT/Org/app/.claude/worktrees/bridge-x" ]
  [ -d "$HOME/wt/stray" ]
  [ ! -s "$CALLS" ]
}

@test "--apply retire envs, worktrees, dossiers, .worktreeinclude et hook" {
  make_repo Org/app
  local app="$WT_DECOM_ROOT/Org/app"
  add_wt Org/app "$HOME/wt/myapp-t1" feature/t1
  mkdir -p "$WT_STATE"
  jq -n --arg p "$HOME/wt/myapp-t1" '[{project:"myapp-t1",app:"myapp",slug:"t1",path:$p}]' > "$WT_STATE/registry.json"
  add_wt Org/app "$app/.claude/worktrees/bridge-x" hotfix/x
  add_wt Org/app "$BATS_TEST_TMPDIR/gone" feature/gone
  rm -rf "$BATS_TEST_TMPDIR/gone"
  printf '.mcp.json\n.env\n' > "$app/.worktreeinclude"
  printf '.mcp.json\n.worktreeinclude\n' >> "$app/.git/info/exclude"
  make_repo Org/tracked
  printf '.mcp.json\n' > "$WT_DECOM_ROOT/Org/tracked/.worktreeinclude"
  git -C "$WT_DECOM_ROOT/Org/tracked" add .worktreeinclude
  git -C "$WT_DECOM_ROOT/Org/tracked" commit -qm include
  echo '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/x/bin/wt-session-hook"}]}]}}' > "$WT_SETTINGS"

  run "$D" --apply
  [ "$status" -eq 0 ]
  grep -qx 'wt destroy myapp t1 --yes' "$CALLS"
  grep -qx 'hook-install --uninstall' "$CALLS"
  [ ! -e "$app/.claude/worktrees" ]
  [ "$(git -C "$app" worktree list | wc -l)" -eq 1 ]
  [ ! -e "$HOME/wt" ]
  [ ! -e "$WT_STATE" ]
  [ ! -e "$app/.worktreeinclude" ]
  run grep -q worktreeinclude "$app/.git/info/exclude"
  [ "$status" -ne 0 ]
  grep -qx '.mcp.json' "$app/.git/info/exclude"
  [ -f "$WT_DECOM_ROOT/Org/tracked/.worktreeinclude" ]
  ls "$WT_SETTINGS".bak-* >/dev/null
}

@test "--apply est idempotent" {
  make_repo Org/app
  add_wt Org/app "$WT_DECOM_ROOT/Org/app/.claude/worktrees/bridge-x" hotfix/x

  run "$D" --apply
  [ "$status" -eq 0 ]
  run "$D" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Démontage terminé"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/decommission.bats`
Expected: les 6 tests de Task 1 `ok` ; les 4 nouveaux `not ok` (`--apply` rejeté comme « option inconnue »).

- [ ] **Step 3: Write the implementation**

In `bin/wt-decommission`, replace the whole final block (from `case "${1:-}" in` to the end of the file) with:

```bash
apply() {
  local app slug repo path pr parent
  [ "$BLOCKERS" -eq 0 ] || die "--apply refusé : $BLOCKERS élément(s) bloquant(s) (À RISQUE, EN USAGE ou INCONNU ci-dessus). Rien n'a été modifié."

  say ""
  say "== Retrait"
  # 1. Environnements du registre : wt destroy porte déjà docker down (profils inclus) + DROP DATABASE.
  if [ -f "$STATE/registry.json" ]; then
    while IFS=$'\t' read -r app slug; do
      [ -n "$app" ] || continue
      say "  wt destroy $app $slug"
      "$WT_BIN" destroy "$app" "$slug" --yes || die "wt destroy $app $slug a échoué ; corriger puis relancer --apply"
    done < <(jq -r '.[] | [.app, .slug] | @tsv' "$STATE/registry.json")
  fi

  # 2. Autres worktrees encore présents (sans --force : git refuse un arbre sale), puis prune.
  while IFS= read -r repo; do
    while IFS=$'\t' read -r path pr; do
      [ -n "$path" ] && [ "$pr" = 0 ] && [ -d "$path" ] || continue
      say "  git worktree remove $path"
      git -C "$repo" worktree remove "$path" || die "retrait impossible : $path"
      parent="$(dirname "$path")"
      case "$parent" in */.claude/worktrees) rmdir "$parent" 2>/dev/null || true ;; esac
    done < <(secondary_worktrees "$repo")
    git -C "$repo" worktree prune
  done < <(repos)

  # 3. Dossiers d'état.
  if [ -d "$WT_DIR" ]; then
    rmdir "$WT_DIR" || die "$WT_DIR n'est pas vide"
    say "  rmdir $WT_DIR"
  fi
  if [ -d "$STATE" ]; then
    rm -rf "$STATE"
    say "  rm -rf $STATE"
  fi

  # 4. .worktreeinclude non versionnés et leur ligne d'exclusion.
  while IFS= read -r repo; do
    [ -f "$repo/.worktreeinclude" ] || continue
    git -C "$repo" ls-files --error-unmatch .worktreeinclude >/dev/null 2>&1 && continue
    rm -f "$repo/.worktreeinclude"
    [ -f "$repo/.git/info/exclude" ] && sed -i '/^\/\{0,1\}\.worktreeinclude$/d' "$repo/.git/info/exclude"
    say "  rm $repo/.worktreeinclude"
  done < <(repos)

  # 5. Hook SessionStart + lien du skill (wt-hook-install --uninstall est idempotent).
  if hook_present; then
    cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
    say "  sauvegarde de $SETTINGS"
  fi
  "$HOOK_INSTALL" --uninstall || die "wt-hook-install --uninstall a échoué"

  say "Démontage terminé."
}

APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  -h|--help) say "usage: wt-decommission [--apply]"; exit 0 ;;
  *) die "option inconnue : $1" ;;
esac
command -v jq >/dev/null || die "jq requis"

inventory
if [ "$APPLY" = 1 ]; then
  apply
else
  say ""
  [ "$BLOCKERS" -gt 0 ] && say "BLOQUANT : $BLOCKERS élément(s) — --apply refusera tant qu'ils ne sont pas traités."
  say "Simulation : rien n'a été modifié. Relancer avec --apply pour exécuter."
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/decommission.bats`
Expected: `1..10`, 10 `ok`.
Then full suite: `bats tests/` → aucun `not ok`.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-decommission tests/decommission.bats
git commit -m "feat(wt): decommission --apply removes envs, worktrees and hook, refusing unsaved work"
```

---

### Task 3: Exécution réelle sur le VPS (point de contrôle avec Simon)

**Files:** aucun changement de code.

**Interfaces:**
- Consumes : `bin/wt-decommission` (Tasks 1-2), `bin/wt destroy`, `bin/wt-hook-install` (encore présents sur la branche).

- [ ] **Step 1: Sauvegarder le travail de `bifacto-doc-sa-org-funnel` (validation Simon obligatoire)**

```bash
cd /home/webadmin/wt/bifacto-doc-sa-org-funnel
git status --short
git log --oneline HEAD --not --remotes
```
Expected (relevé du 2026-09-15) : 5 fichiers modifiés (`src/Controller/PortfolioController.php`, `tests/Controller/PortfolioControllerTest.php`, `translations/messages.{bg,en,fr}.yaml`) et 8 commits non poussés sur `feature/sa-org-funnel`.
Montrer ces sorties et le diff à Simon ; **attendre son accord** sur le message de commit et le push. Puis :
```bash
git add src/Controller/PortfolioController.php tests/Controller/PortfolioControllerTest.php translations/messages.bg.yaml translations/messages.en.yaml translations/messages.fr.yaml
git commit -m "<message validé par Simon, en anglais, sans mention d'IA>"
git push -u origin feature/sa-org-funnel
```

- [ ] **Step 2: Vérifier le prérequis de `wt destroy`**

```bash
cd /home/webadmin/Project/Infra
grep -q '^MYSQL_ROOT_PASSWORD=' .env && echo OK
```
Expected: `OK` (le `DROP DATABASE` de `wt destroy` lit ce mot de passe).

- [ ] **Step 3: Simulation**

Run: `bin/wt-decommission`
Expected (état du 2026-09-15, après Step 1) :
- `SAUF` : `~/wt/bifacto-doc-sa-org-funnel`, `~/wt/myprojekt-app-projekt-7f`, `~/Project/Diplam09/doc-session-cleanup`, `~/Project/2JDB/stream.consotrust.com/.claude/worktrees/bridge-cse_01AtZYat8Hq5KzRsN69x4qPz` ;
- `MANQUANT` : `~/Project/Diplam09/app.bifacto.com--hotfix-tarteaucitron` ;
- registre : `myprojekt-app-projekt-7f`, `bifacto-doc-sa-org-funnel` ;
- 11 `.worktreeinclude` « à supprimer » (les 2 de `ReseauCharon/reseau-charon-creation.fr` et `Asteria/france-ermitage.fr` ne sont pas dans des repos git : non listés, laissés) ;
- hook et skill : présents ; aucune ligne `BLOQUANT`.

Si la sortie diffère (nouvel élément `À RISQUE`, `EN USAGE`, `INCONNU`), s'arrêter et en parler à Simon.

- [ ] **Step 4: Validation explicite de Simon**

Présenter la sortie complète et rappeler ce qui est irréversible : `docker compose down -v` et `DROP DATABASE` des 2 environnements, retrait de 4 worktrees. **Ne pas continuer sans un « oui » explicite.**

- [ ] **Step 5: Exécution**

Run: `bin/wt-decommission --apply`
Expected: se termine par `Démontage terminé.`, exit 0.

- [ ] **Step 6: Vérifier**

```bash
docker ps -a --format '{{.Names}}' | grep -E 'sa-org-funnel|projekt-7f' || echo "conteneurs: OK"
cd /home/webadmin/Project && for r in */.git */*/.git; do [ -d "$r" ] && n=$(git -C "${r%/.git}" worktree list | wc -l) && [ "$n" -gt 1 ] && echo "RESTE: ${r%/.git}"; done; echo "worktrees: vérifié"
ls -d ~/wt ~/.local/state/wt 2>/dev/null || echo "dossiers: OK"
jq '.hooks.SessionStart' ~/.claude/settings.json
ls ~/.claude/skills
```
Expected: `conteneurs: OK` ; aucune ligne `RESTE:` ; `dossiers: OK` ; `SessionStart` = `null` ; `~/.claude/skills` sans `worktree-env`. Les hooks `PreToolUse` (`guard-branch-clean`, `prod-guard`) sont intacts.

---

### Task 4: Dashboard sans worktrees

**Files:**
- Modify: `bin/wt-metrics`, `dashboard/server/api.php`, `dashboard/server/router.php`, `dashboard/public/index.html`, `dashboard/public/app.js`, `dashboard/public/style.css`, `docs/wt-dashboard-README.md`
- Delete: `dashboard/server/destroy.php`, `tests/api-destroy.bats`
- Test: `tests/metrics.bats`, `tests/metrics-docker-sessions.bats`, `tests/dash-smoke.bats`, `tests/api.bats`, `tests/frontend.bats`

**Interfaces:**
- Produces : `bin/wt-metrics all` → objet JSON à **quatre** clés `system`, `disk`, `docker`, `sessions` ; `bin/wt-metrics worktrees` → exit 2. `GET /api/metrics` : mêmes quatre clés. Plus aucune route d'écriture.

- [ ] **Step 1: Write the failing tests**

`tests/metrics.bats` — replace the test `all emits an object with the five sections` with:
```bash
@test "all emits an object with the four sections and no worktrees" {
  run "$M" all
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("sessions") and (has("worktrees")|not)' >/dev/null
}
@test "worktrees section no longer exists" { run "$M" worktrees; [ "$status" -ne 0 ]; }
```

`tests/metrics-docker-sessions.bats` — replace lines 15-21 (stub `wt` + exports) with:
```bash
  export PATH="$BIN:$PATH"
```
and delete the test `worktrees section enriches wt list with disk_bytes` (lines 27-30).

`tests/dash-smoke.bats` line 10 becomes:
```bash
  echo "$output" | jq -e 'has("system") and has("docker") and has("sessions") and has("disk") and (has("worktrees")|not)' >/dev/null
```

`tests/api.bats` — in the two tests `metrics endpoint degrades to a safe default when wt-metrics emits invalid JSON` and `… emits nothing`, the `jq -e` line becomes:
```bash
  echo "$output" | jq -e 'has("system") and has("disk") and has("docker") and has("sessions") and (has("worktrees")|not)' >/dev/null
```
and replace the test `router does not require destroy.php for a plain metrics GET` with:
```bash
@test "router answers not found to the former POST destroy route" {
  run php -r '
    $_SERVER["REQUEST_URI"]="/api/worktrees/x/destroy"; $_SERVER["REQUEST_METHOD"]="POST";
    require getenv("WT_ROOT")."/dashboard/server/router.php";
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -f "$WT_ROOT/dashboard/server/destroy.php" ]
}
```

`tests/frontend.bats` — line 6 becomes:
```bash
  for id in system docker sessions disk; do grep -q "id=\"$id\"" "$P/index.html"; done
```
replace the test `app.js polls /api/metrics and wires destroy; index exposes CSV export + search` with:
```bash
@test "app.js polls /api/metrics; index exposes CSV export + search" {
  grep -q '/api/metrics' "$P/app.js"
  grep -qi 'setInterval\|setTimeout' "$P/app.js"
  grep -q 'metrics.csv' "$P/index.html"
  grep -q 'id="q"' "$P/index.html"
}
@test "no worktree UI nor destroy action remains" {
  run grep -qiE 'worktree|/destroy|\.wt[-{:]' "$P/index.html" "$P/app.js" "$P/style.css"
  [ "$status" -eq 1 ]
}
```

Delete: `git rm tests/api-destroy.bats`

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/metrics.bats tests/dash-smoke.bats tests/api.bats tests/frontend.bats`
Expected: `not ok` sur `all emits … no worktrees`, `worktrees section no longer exists`, `wt-metrics all is valid JSON…`, les 2 tests `degrades…`, `router answers not found…`, `no worktree UI nor destroy action remains`.

- [ ] **Step 3: Write the implementation**

`bin/wt-metrics` :
- delete lines `HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` and `WT_BIN="${WT_METRICS_WT:-$HERE/wt}"` ;
- delete the whole function `m_worktrees() { … }` ;
- replace `m_all` and the final `case` with:
```bash
m_all() {
  jq -n --argjson system "$(m_system)" --argjson disk "$(m_disk)" \
        --argjson docker "$(m_docker)" --argjson sessions "$(m_sessions)" \
    '{system:$system,disk:$disk,docker:$docker,sessions:$sessions}' 2>/dev/null || echo '{}'
}
case "${1:-}" in
  system) m_system;; disk) m_disk;; docker) m_docker;; sessions) m_sessions;; all) m_all;;
  *) echo "usage: wt-metrics system|disk|docker|sessions|all" >&2; exit 2;;
esac
```

`dashboard/server/api.php` :
- `wt_api_metrics_default()` returns `'{"system":{},"disk":[],"docker":[],"sessions":[]}'` ;
- in the docblock of `wt_api_metrics()`, `carrying all five expected keys` → `carrying all four expected keys` ;
- in `wt_api_csv()`, delete the block from `$worktrees = $metrics['worktrees'] ?? [];` through its closing `}`.

`dashboard/server/router.php` : delete the block
```php
if ($method === 'POST' && preg_match('#^/api/worktrees/([^/]+)/destroy$#', $uri, $m)) {
    …
    return true;
}
```
(the request then falls through to the static-file guard, which answers `404` / `not found`).

`git rm dashboard/server/destroy.php`

`dashboard/public/index.html` :
- placeholder becomes `placeholder="Filtrer projets, containers, sessions…"` ;
- delete the `<section id="worktrees" class="panel"> … </section>` block and the blank line after it.

`dashboard/public/app.js` :
- delete the block from `// --- worktrees ---…` through the end of `function renderWorktrees(list) { … }` and the blank line after it ;
- delete the block from `// --- actions ---…` through the end of `function destroy(project) { … }` and the blank line after it ;
- in `applyFilter()`, replace
  ```js
    // lignes simples (worktrees, disk)
    ['worktrees', 'disk'].forEach(function (id) {
  ```
  with
  ```js
    // lignes simples (disk)
    ['disk'].forEach(function (id) {
  ```
- in `refresh()`, delete the line `renderWorktrees(data.worktrees);`.

`dashboard/public/style.css` : delete from `/* Worktrees */` through the `.wt-sub{…}` rule (2 lines) and the blank line after it — `.btn` and `.btn.danger` included, used only by worktree rows.

`docs/wt-dashboard-README.md` :
- lines 3-7 become:
  ```markdown
  A small read-only web dashboard for observing the VPS: system load, running docker
  containers, active Claude sessions, and disk usage. It reads what `docker stats`
  and the host already know. Worktrees were removed on 2026-09-15; this dashboard is
  replaced by the console (see `docs/2026-09-15-work-console-design.md`, lot 3).
  ```
- line 11: `aggregates five sections` → `aggregates four sections` ; delete line 17 (`- **worktrees** — …`) ;
- replace the whole `## Safe actions` section (lines 27-38) with:
  ```markdown
  ## Actions

  None: the dashboard is strictly read-only. There is no way to stop a session or a
  docker stack from the UI, and no metric history beyond the in-memory sparklines.
  ```
- delete the prerequisite bullet `- \`wt\` (this repo's \`bin/wt\`) — …` (lines 47-48) ;
- security note (lines 76-78): `would expose \`POST /api/worktrees/{project}/destroy\` and the info-leaking \`GET /api/metrics\`` → `would expose the info-leaking \`GET /api/metrics\`` ;
- delete the table row `| \`WT_DASH_WT\` | … |` (line 86).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/`
Expected: aucun `not ok`.
Then: `grep -rniE 'worktree|destroy' dashboard/ bin/wt-metrics` → aucune sortie.

- [ ] **Step 5: Commit**

```bash
git add bin/wt-metrics dashboard/ docs/wt-dashboard-README.md tests/metrics.bats tests/metrics-docker-sessions.bats tests/dash-smoke.bats tests/api.bats tests/frontend.bats
git commit -m "refactor(dashboard): drop worktrees section and destroy action"
```

---

### Task 5: Retrait du moteur `wt`, du hook et du skill

**Files:**
- Delete: `bin/wt`, `bin/wt-hook-install`, `bin/wt-session-hook`, `bin/wt-decommission`, `lib/` (entier), `etc/wt/`, `skills/worktree-env/`, `tests/fixtures/`, `tests/{create,destroy,cli,doctor,gitwt,list,smoke,db,docker,envgen,naming,profile,registry,hook,hook-entrypoint,hook-install,hook-smoke,skill,decommission}.bats`, `docs/wt-README.md`, `docs/wt-hook-README.md`
- Keep: `tests/helpers.bash`, `bin/wt-metrics`, `bin/wt-dash-install`, `dashboard/`, specs et plans du 2026-09-05.

**Interfaces:**
- Consumes : Task 3 exécutée (le VPS n'utilise plus `wt`), Task 4 (le dashboard ne dépend plus de `bin/wt`).

- [ ] **Step 1: Vérifier que rien de conservé ne dépend du code à supprimer**

Run:
```bash
grep -rnE 'bin/wt([^-]|$)|lib/|wt-session-hook|wt-hook-install|worktree-env|etc/wt|fixtures/' \
  bin/wt-metrics bin/wt-dash-install dashboard Makefile README .gitignore \
  tests/helpers.bash tests/api.bats tests/frontend.bats tests/dash-smoke.bats tests/dash-install.bats tests/metrics.bats tests/metrics-docker-sessions.bats
```
Expected: aucune sortie. Si une ligne apparaît, la corriger dans cette tâche avant de supprimer.

- [ ] **Step 2: Supprimer**

```bash
git rm -r -q bin/wt bin/wt-hook-install bin/wt-session-hook bin/wt-decommission lib etc/wt skills/worktree-env tests/fixtures \
  tests/create.bats tests/destroy.bats tests/cli.bats tests/doctor.bats tests/gitwt.bats tests/list.bats tests/smoke.bats \
  tests/db.bats tests/docker.bats tests/envgen.bats tests/naming.bats tests/profile.bats tests/registry.bats \
  tests/hook.bats tests/hook-entrypoint.bats tests/hook-install.bats tests/hook-smoke.bats tests/skill.bats tests/decommission.bats \
  docs/wt-README.md docs/wt-hook-README.md
```

- [ ] **Step 3: Run the full suite**

Run: `bats tests/`
Expected: aucun `not ok` (restent `api`, `dash-install`, `dash-smoke`, `frontend`, `metrics`, `metrics-docker-sessions`).
Then: `git ls-files | grep -E '^(lib|etc/wt|skills)/'` → aucune sortie.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: remove wt worktree engine, session hook and skill"
```

---

### Task 6: PR et déploiement

**Files:** aucun.

- [ ] **Step 1: Validation de Simon, puis push et PR**

Présenter `git log --oneline main..chore/decommission-wt` à Simon ; **attendre son accord**. Puis :
```bash
git push -u origin chore/decommission-wt
gh pr create --base main --head chore/decommission-wt \
  --title "chore: decommission wt worktrees (lot 1)" \
  --body "Removes the wt worktree tooling (engine, SessionStart hook, skill) after a one-shot decommission run on the VPS, and drops the worktrees section and destroy action from the dashboard. Includes the design spec for the work CLI, write guard and console (docs/2026-09-15-work-console-design.md). Test suite green."
git switch main
```
(Retour sur `main` après ouverture de la PR, conformément au workflow validé.)

- [ ] **Step 2: Après le merge par Simon**

```bash
cd /home/webadmin/Project/Infra
git switch main && git pull --ff-only
git branch -D chore/decommission-wt docs/work-console-spec
curl -sk --resolve worktree.docker.test:443:100.75.44.109 -u "admin:$(cat ~/.wt-dashboard-credential)" \
  https://worktree.docker.test/api/metrics | jq -c 'keys'
```
Expected: `["disk","docker","sessions","system"]` (le service `php -S` sert les fichiers en direct : pas de redémarrage).
