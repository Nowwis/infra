# Lot 2 — `work` + garde d'écriture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un CLI `work` qui porte le workflow gitflow validé (un seul checkout par projet, un ticket en écriture à la fois) et un hook `PreToolUse` qui bloque toute écriture Claude hors ticket démarré ou par une autre session.

**Architecture:** L'état d'un projet vit dans `<git-common-dir>/claude-work.json`, sérialisé par `flock`. `bin/work` (bash) le fait évoluer ; `bin/work-guard` (python3, `shlex` pour analyser les commandes Bash) le lit pour décider ; `bin/work-session-hook` (bash) l'affiche au démarrage d'une session. Rien n'est activé dans `~/.claude/settings.json` par ce lot : `bin/work-hook-install` est livré mais lancé seulement avec Simon.

**Tech Stack:** bash 5, git, jq, flock, gh, python3 3.12 (stdlib uniquement), bats 1.10.

**Spec:** `docs/2026-09-15-work-console-design.md` §4.

## Global Constraints

- Branche `feat/work-cli`, empilée sur `chore/decommission-wt` (PR #15) ; PR ciblant `main` après merge de #15 (sinon ciblant `chore/decommission-wt`).
- Commits en anglais, **aucune mention de Claude / IA, aucun trailer `Co-Authored-By`** ; jamais `git add -A` (route Traefik NOWIA non commitée).
- **Aucune activation** : ne pas lancer `bin/work-hook-install`, ne pas modifier `~/.claude/settings.json`, ne pas toucher `~/.claude/skills/start-ticket`, ne créer aucun `claude-work.json` dans les vrais repos. Activation + migration (§4.7) = avec Simon.
- Tests : jamais le vrai `$HOME` ni les vrais repos ; `gh` toujours simulé par un stub dans le `PATH`.
- Messages utilisateur des outils en français.
- Suite `bats tests/` verte à la fin de chaque tâche.

## Décisions d'implémentation (précisent la spec)

- `etc/work/projects.conf` : `nom|repo|main|develop|forge`. 14 repos. Exclus : `AgentIA/hermes-webui` (repo tiers), `_nowia` (pas de remote), `Diplam09/services-rest.bifacto.com` (GitLab tiers, référence cassée).
- Surcharges d'environnement (tests) : `WORK_CONF`, `WORK_SESSIONS_DIR` (défaut `~/.claude/sessions`), `WORK_GUARD=off`.
- Identité : `CLAUDE_CODE_SESSION_ID`, sinon `human:<user>`. Une identité `human:*` est toujours considérée vivante. Une session Claude est vivante si un `$WORK_SESSIONS_DIR/*.json` a ce `sessionId` et un `pid` vivant.
- Nom de branche : `feature/<KEY>[-<slug>]` ou `hotfix/<KEY>[-<slug>]` ; `KEY` et `slug` limités à `[A-Za-z0-9._-]`.
- Appels `gh` (forme fixe, exécutés depuis le repo) : `gh pr view <branch> --json state --jq .state` ; `gh pr view <branch> --json number,url --jq '[.number,.url]|@tsv'` ; `gh pr create --base <base> --head <branch> --title <T> --body-file <F>`.
- URL de MR GitLab : `https://<host>/<path>/-/merge_requests/new?merge_request[source_branch]=<branch>&merge_request[target_branch]=<base>`.
- Garde : blocage = exit 2 + message stderr ; toute exception interne = exit 0 (fail-open). La journalisation des blocages arrive au lot 4.

---

### Task 1: Configuration, bibliothèque commune, `work status`

**Files:** Create `etc/work/projects.conf`, `lib/work/common.sh`, `bin/work`, `tests/work-helpers.bash`, `tests/work-common.bats`

**Interfaces (Produces):**
- `work_project_for_path <path>` → exporte `WP_NAME WP_REPO WP_MAIN WP_DEVELOP WP_FORGE` (plus long préfixe) ; retour 1 si hors projet.
- `work_session_id` ; `work_session_alive <id>` (0 = vivante).
- `work_state_file` ; `work_state_get` (JSON, défaut `{"state":"free","pending_prs":[]}`) ; `work_state_put <json>` (écriture atomique) ; `work_locked <fonction> [args]` (flock 10 s).
- `work_is_clean` ; `work_current_branch` ; `work_sync_bases` ; `work_check_name <str>`.
- `work status [--all] [--json]` : objet (ou tableau avec `--all`) `{name, repo, state, ticket, branch, owner, owner_alive, is_me, current_branch, dirty, pending_prs, drift[]}` ; `drift` ∈ `hors-workflow` (free et (dirty>0 ou branche ≠ main)), `verrou-orphelin` (active et propriétaire mort).

**Tests (`tests/work-common.bats`) :** résolution par plus long préfixe et hors projet ; état par défaut quand le fichier est absent ; put/get aller-retour ; session vivante/morte/humaine ; `sync_bases` avance main et develop en avance rapide depuis origin, y compris la branche non checkoutée, et échoue sur divergence ; `status --json` d'un projet libre et propre ; drift `hors-workflow` (fichier modifié / branche ≠ main) ; drift `verrou-orphelin`.

- [ ] Step 1: écrire `tests/work-helpers.bash` (`setup_work`, `make_project <name> [nodevelop] [gitlab]`, stub `gh` piloté par `$GH_DIR`) et `tests/work-common.bats`
- [ ] Step 2: `bats tests/work-common.bats` → FAIL
- [ ] Step 3: écrire `lib/work/common.sh`, `bin/work` (dispatch + `status`), `etc/work/projects.conf`
- [ ] Step 4: `bats tests/` → vert
- [ ] Step 5: commit `feat(work): add project config, state store and status command`

### Task 2: `work start` et ménage automatique

**Files:** Modify `bin/work` ; Create `lib/work/cmd_start.sh`, `tests/work-start.bats`

**Tests :** feature tirée de develop avec main et develop pullés ; hotfix tirée de main ; repli sur main sans develop ; état `active` au nom de la session ; refus si `active`, si arbre sale, si branche existe en local ou sur origin, si nom invalide (rien de modifié) ; avertissement si `pending_prs` ; ménage : entrée GitHub `MERGED` → branche locale supprimée et entrée retirée, `OPEN` et `parked` conservées ; deux `start` concurrents → un seul réussit.

- [ ] Step 1-5 (TDD) ; commit `feat(work): start a ticket from synced main/develop`

### Task 3: `work pr` et `work merged`

**Files:** Create `lib/work/cmd_pr.sh`, `lib/work/cmd_merged.sh`, `tests/work-pr-merged.bats`

**Tests :** `pr` pousse, crée la PR (base develop/main) via `gh pr create`, revient sur main pullé, déplace le ticket dans `pending_prs` (number, url), état `free` ; PR déjà ouverte réutilisée sans `create` ; titre/corps manquants sans PR existante → refus avant push ; refus si autre propriétaire, mauvaise branche, arbre sale ; GitLab : affiche l'URL de MR, pas d'appel `gh`. `merged` : `MERGED` → base synchronisée, branche supprimée, entrée retirée, branche checkoutée inchangée ; `OPEN` → refus ; KEY facultatif s'il n'y a qu'une entrée, requis sinon ; GitLab exige `--confirmed`.

- [ ] Step 1-5 (TDD) ; commit `feat(work): open PR then return to main, and verified merged cleanup`

### Task 4: `resume`, `park`, `adopt`, `takeover`

**Files:** Create `lib/work/cmd_resume.sh`, `lib/work/cmd_park.sh`, `lib/work/cmd_adopt.sh`, `lib/work/cmd_takeover.sh`, `tests/work-resume-park.bats`

**Tests :** `park` commite `wip: <KEY> parked` si besoin, pousse, revient sur main, entrée `parked:true`, état `free` ; `resume` repasse sur la branche (pull si distante), état `active`, entrée retirée ; refus de `resume` si `active` ou KEY inconnu ; `adopt` sur une branche ≠ main/develop → `active` (base main pour `hotfix/*`), refus sur main ; `takeover` réattribue et affiche l'ancien propriétaire et son état.

- [ ] Step 1-5 (TDD) ; commit `feat(work): resume, park, adopt and takeover`

### Task 5: Classifieur de commandes et hook `work-guard`

**Files:** Create `bin/work-guard` (python3), `tests/work-classify.bats`, `tests/work-guard.bats`

**Interfaces:** `work-guard --classify <cmd> --cwd <dir>` → JSON `{"targets":[…]}` (chemins touchés en écriture) ; mode hook : JSON PreToolUse sur stdin.

**Tests classifieur (table) :** écritures (`git commit`, `git checkout -b x`, `git branch x`, `git branch -D x`, `git -C /r stash`, `sed -i`, `rm`, `echo x > f`, `composer require`, `npm ci`, `make test`, `php bin/console doctrine:migrations:migrate`, `vendor/bin/phpunit`, `docker compose up -d`, `docker compose exec php bin/console cache:clear`, `bash -c "git commit"`, `cd /r && git commit`, `echo $(git commit)`) ; lectures (`git status`, `git log`, `git diff`, `git fetch`, `git branch`, `git branch -a`, `git stash list`, `cat f`, `grep`, `ls`, `docker logs x`, `echo x > /tmp/f`, `bin/work start X`, `/home/…/Infra/bin/work pr`) ; cibles = cwd effectif, `-C`, chemins absolus des segments d'écriture, cibles de redirection.

**Tests hook :** Edit hors projet → 0 ; fichier ignoré par git → 0 ; projet `free` → 2 avec « aucun ticket démarré » ; `active` même session et bonne branche → 0 ; mauvaise branche → 2 ; autre session vivante → 2 « lecture seule » ; autre session morte → 2 avec « work takeover » ; Bash lecture sur projet `free` → 0 ; `WORK_GUARD=off` → 0 ; JSON invalide → 0 ; durée < 300 ms.

- [ ] Step 1-5 (TDD) ; commit `feat(work): add write guard hook with bash command classifier`

### Task 6: Hook SessionStart, installateur, skill

**Files:** Create `bin/work-session-hook`, `bin/work-hook-install`, `skills/work/SKILL.md`, `tests/work-session-hook.bats`, `tests/work-hook-install.bats`

**Tests :** session hook : silencieux hors projet ; contexte « libre — lecture seule tant que `work start` n'est pas fait » ; « ticket X tenu par toi » ; « tenu par une autre session » ; PR en attente listées ; dérive signalée ; JSON `hookSpecificOutput.additionalContext` valide ; exit 0 sur entrée invalide. Installateur (sur un `settings.json` temporaire) : ajoute `PreToolUse` (matcher `Edit|MultiEdit|Write|NotebookEdit|Bash`) et `SessionStart`, retire `guard-branch-clean.sh`, préserve `prod-guard.sh`, lien du skill, idempotent ; `--uninstall` retire ses entrées et le lien. Skill : frontmatter `name`/`description`, mentionne `work start|pr|merged|resume|park|status` et les validations avant push.

- [ ] Step 1-5 (TDD) ; commit `feat(work): session hook, installer and work skill`

### Task 7: Spec, PR

- [ ] Mettre à jour la spec §4.1 (repos exclus) ; `bats tests/` vert
- [ ] Push `feat/work-cli`, PR (base `chore/decommission-wt` tant que #15 n'est pas mergée), retour sur `main`
