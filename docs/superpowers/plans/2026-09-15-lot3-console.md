# Lot 3 — Console v1 (lecture seule) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer le dashboard `wt` par une console en lecture seule dont la page ne lance plus aucune commande : un collecteur en tâche de fond écrit un instantané, la page le lit toutes les 2 s et affiche vitals, diagnostics, projets (`work`), sessions Claude, Docker et disques.

**Architecture:** `bin/console-collector` (bash) calcule des sections à cadences différenciées et les écrit atomiquement dans `~/.local/state/console/sections/<nom>.json`, puis assemble `snapshot.json`. `console/server` (PHP, `php -S`) sert `GET /api/snapshot` (+ indicateur `stale`) et le CSV ; `console/public` rend le tout. Deux unités systemd utilisateur : `console-web`, `console-collector`.

**Tech Stack:** bash 5, jq, docker CLI, gh, PHP 8.3, JS sans dépendance, bats 1.10.

**Spec:** `docs/2026-09-15-work-console-design.md` §5.

## Global Constraints

- Branche `feat/console`, empilée sur `feat/work-cli` (PR #16).
- Commits en anglais, **aucune mention de Claude / IA, aucun trailer** ; jamais `git add -A`.
- **Aucun déploiement** : ne pas installer les unités, ne pas arrêter `wt-dashboard`, ne pas modifier `configuration/traefik2/config/dynamic_conf.local.yaml` (modification runtime NOWIA non commitée sur ce fichier ; le renommage de route se fait au déploiement, avec Simon).
- La page ne lance aucune commande ; aucune route d'écriture ; rendu DOM par `textContent` uniquement.
- Tests : sources simulées (`CONSOLE_PROC`, stubs `docker`/`gh`/`ps` dans le `PATH`, `CONSOLE_SESSIONS_DIR`, `WORK_CONF`) ; jamais les vraies données dans les assertions.
- Suite `bats tests/` verte à la fin de chaque tâche.

## Contrats

- Fichier de section : `{"collected_at": <epoch s>, "cadence": <s>, "data": <JSON>}`.
- `snapshot.json` : `{"generated_at": <epoch s>, "sections": {"<nom>": <fichier de section>}}`.
- `GET /api/snapshot` : l'instantané, chaque section enrichie de `"stale": true|false` (âge > 3 × cadence) ; fichier absent → `{"generated_at": null, "sections": {}, "missing": true}`.
- CLI : `console-collector run` (boucle) ; `console-collector once <section>` (calcule, écrit, affiche la section) ; `console-collector assemble` (écrit et affiche l'instantané).
- Sections et cadences : `system` 2 s, `sessions` 5 s, `projects` 10 s, `docker` 15 s, `diagnostics` 15 s, `disk` 60 s, `prs` 300 s (tâche de fond), `docker_df` 600 s (tâche de fond).
- Variables : `CONSOLE_STATE` (défaut `~/.local/state/console`), `CONSOLE_PROC` (défaut `/proc`), `CONSOLE_SESSIONS_DIR` (défaut `~/.claude/sessions`), `WORK_CONF`, `CONSOLE_SNAPSHOT` (API, défaut `$CONSOLE_STATE/snapshot.json`).

---

### Task 1: Renommage dashboard → console

**Files:** `git mv dashboard console` ; `bin/wt-dash-install` → `bin/console-install` ; `dashboard/dashboard.env.example` → `console/console.env.example` ; tests `api`, `frontend`, `dash-smoke`, `dash-install` → `console-api`, `console-frontend`, `console-smoke`, `console-install` ; `tests/helpers.bash` (`setup_wt`/`WT_ROOT` → `setup_infra`/`INFRA_ROOT`, sans `WT_STATE`) et tous les tests qui l'utilisent ; `Makefile` (`console-deploy`) ; `.gitignore` ; `docs/wt-dashboard-README.md` → `docs/console-README.md`.

- Installateur : variables `CONSOLE_*`, unité `console-web.service`, secret `configuration/traefik2/certs/console.htpasswd`, `--uninstall`.
- Tests : suite existante renommée, verte ; `grep -rn 'wt-dash\|WT_DASH\|setup_wt\|WT_ROOT' bin console tests Makefile .gitignore` vide.
- Commit `refactor(console): rename dashboard to console`

### Task 2: Collecteur — cadre, `system`, `disk`

**Files:** Create `bin/console-collector`, `lib/console/collect.sh`, `lib/console/section_system.sh`, `lib/console/section_disk.sh`, `tests/console-collector.bats` ; Delete `bin/wt-metrics`, `tests/metrics.bats`, `tests/metrics-docker-sessions.bats`.

- `system` : mémoire, swap, charge, nb CPU, PSI (`cpu.some_avg10`, `memory.some_avg60`, `memory.full_avg60`, `io.some_avg60`), `oom_kill_total` (`vmstat`).
- `disk` : points de montage (`size`, `used`, `avail` en Ko, `use_pct` nombre).
- Tests : `once system` sur un `/proc` simulé ; `once disk` ; fichier de section atomique avec `collected_at`/`cadence` ; `assemble` regroupe les sections présentes ; section inconnue → exit ≠ 0 ; une section en échec n'empêche pas les autres (`data` par défaut).
- Commit `feat(console): collector framework with system and disk sections`

### Task 3: `docker` et `docker_df`

- `docker` : `docker ps -a` (nom, état, statut, labels compose `project`/`working_dir`), `docker inspect` (redémarrages, santé), `docker stats --no-stream` (CPU, mémoire) ; `project` = projet `work` dont le repo contient `working_dir`, sinon le projet compose.
- `docker_df` : `docker system df` → `[{type, size, reclaimable}]`.
- Tests avec stub `docker` : jointure stats/inspect/labels ; conteneur arrêté sans stats ; rattachement au projet `work` ; docker absent → `[]`.
- Commit `feat(console): docker and docker disk usage sections`

### Task 4: `sessions`

- Source : `$CONSOLE_SESSIONS_DIR/*.json` à pid vivant ; champs `session_id`, `pid`, `name`, `kind`, `cwd`, `tmux` (nom de session tmux), `started_at`, `age_s`, `project` (plus long préfixe), `system` (cwd sous `~/.claude-mem`), `rss_kb` (pid + descendants, via un seul `ps`), `mcp` (commandes descendantes contenant `mcp`), `ticket` (si la session tient le verrou `work` du projet).
- `mcp_orphans` (niveau section) : processus `mcp` hors de l'arbre de toute session vivante, groupés par commande.
- Tests avec `ps` stubé et fichiers de session : vivante/morte ; RSS de l'arbre ; tmux ; système ; ticket tenu ; orphelins.
- Commit `feat(console): sessions section with process tree memory and mcp orphans`

### Task 5: `projects` et `prs`

- `projects` : `work status --all --json`, enrichi de l'état GitHub des `pending_prs` lu dans la section `prs`.
- `prs` : pour chaque entrée GitHub en attente, `gh pr view <branch> --json state` → `{ "<repo>": { "<branch>": "OPEN|MERGED|CLOSED" } }`.
- Tests : projet libre/actif ; PR mergée signalée `merged_locally_pending` ; `gh` en échec → état absent, pas d'erreur.
- Commit `feat(console): projects and pull request sections`

### Task 6: `diagnostics`

- Détecteurs (niveaux `ok|warn|crit`, `{id, level, title, detail, action}`) : RAM disponible (< 20 % / < 10 %), swap (> 50 % / > 80 %), PSI mémoire `some_avg60` (> 10 / > 25), PSI io (> 20 / > 40), disque par montage (> 85 % / > 95 %), OOM (hausse de `oom_kill_total` sur 24 h, historique dans `$CONSOLE_STATE/oom_history`), conteneurs `unhealthy` ou redémarrés depuis le passage précédent (≥ 3 en 15 min → crit), unités systemd utilisateur en échec (hors `init.scope`), serveurs MCP orphelins (> 3 / > 10), verrous `work` tenus par une session terminée, sources indisponibles (`warn`).
- Tests sur sections simulées : chaque seuil franchi et non franchi ; hausse OOM ; section manquante → diagnostic « source indisponible ».
- Commit `feat(console): diagnostics section with thresholds`

### Task 7: API et interface

- `console/server/api.php` : `console_api_snapshot()` (lecture, `stale`, `missing`), `console_api_csv()` ; router : `GET /api/snapshot`, `GET /api/snapshot.csv`, statique ; plus aucun `shell_exec`.
- `console/public` : vitals (RAM, swap, CPU + PSI, disque /) → diagnostics non `ok` → Projets → Sessions (par projet, tmux, RAM, ticket) → Docker (par projet, redémarrages, santé) → Disques ; rafraîchissement 2 s ; indicateur « données périmées » ; recherche, repli mémorisé, thème clair/sombre conservés.
- Tests : API sur instantanés simulés (frais, périmé, absent), CSV avec neutralisation des formules, router, absence de `shell_exec`, frontend (sections, `/api/snapshot`, pas de `innerHTML`), smoke `php -S`.
- Commit `feat(console): snapshot API and read-only console UI`

### Task 8: Installation, documentation, PR

- `bin/console-install` : unités `console-web.service` et `console-collector.service` (`Restart=always`), secret htpasswd, `--uninstall` ; `make console-deploy`.
- `docs/console-README.md` : architecture, sections, diagnostics, installation, **procédure de bascule** (arrêt `wt-dashboard`, route Traefik `console` + référence NOWIA à `console.htpasswd`, `docker restart infra_traefik`, vérification 401/200).
- `bats tests/` vert ; push `feat/console` ; PR (base `feat/work-cli`) ; retour sur `main`.
