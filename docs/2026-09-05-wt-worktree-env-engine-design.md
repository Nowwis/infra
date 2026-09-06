# Moteur `wt` — envs de worktree isolés (design)

Date : 2026-09-05 · Statut : design validé (en attente de relecture) · Portée : **sous-projet 1/3 — le moteur CLI**

## 1. Contexte & objectif

Sessions Claude permanentes par app (via remote-control, mobile/PC). Besoin : travailler **plusieurs tickets en parallèle** sur une même app, chacun dans un **environnement de dev complètement isolé** (code + docker + domaine + base), créé/détruit sans effort. Le moteur `wt` est la **fondation** : une CLI bash qui orchestre tout le cycle de vie d'un env de worktree. Hook Claude, skill et dashboard (sous-projets 2 et 3) ne feront que **l'appeler**.

## 2. Périmètre

**Dans le périmètre (v1) :**
- CLI `wt` : `create`, `list`, `destroy`, `open`, `doctor`.
- Cycle complet : branche+worktree git, `.docker/.env` généré, DB de dev dédiée, `docker compose up`, `make install`+yarn, teardown symétrique.
- **Apps Symfony uniquement** : `myprojekt-app`, `bifacto-doc`, `consotrust`, `lagestionenligne`, `parisrental`.

**Hors périmètre :**
- Hook `SessionStart` + skill (sous-projet 2), dashboard web + métriques (sous-projet 3).
- Apps **PrestaShop** (`uspiecesautos`, `direkto`) : install/DB différents → v2.
- Clonage de données de prod : la DB part de **schéma + migrations (+ fixtures)**.

## 3. Contraintes & faits d'infra (vérifiés)

- VPS 4 vCPU / 16 Go. **Empiler des stacks est coûteux** (php+nginx+node, parfois rabbitmq/mercure) → garde-fou ressources nécessaire.
- **`*.docker.test` = wildcard dnsmasq → `100.75.44.109` (Traefik)** : tout sous-domaine résout tout seul, Traefik route par label → **domaine gratuit par worktree**.
- **MariaDB partagé** : container `infra_mariadb_11_3`, alias réseau `infra_mysql_8_0` (host utilisé dans `DATABASE_URL`). Creds admin dans `Infra/.env` (`MYSQL_ROOT_PASSWORD`).
- Réseaux docker externes partagés : `traefik`, `databases`, `mailer`.
- Template docker : `Project/_DOCKER/.docker/` ; chaque repo a son `.docker/docker-compose.yml` + `.docker/.env` (suivi) paramétrés par `COMPOSE_PROJECT_NAME`, `COMPOSE_PROJECT_DOMAIN`, `APP_FOLDER`, `PROJECT_TYPE`, `PHP_VERSION`…
- `.env.local` porte `APP_URL=https://<app>.docker.test` et `DATABASE_URL=mysql://<user>:<pwd>@infra_mysql_8_0/<db>?...`.
- Makefile expose `up`, `down`, `yarn`, `exec`, `update-app` (cible `install` appelée si présente).

## 4. Architecture

Bash, au niveau système (agnostique au langage des apps ; délègue le build au Makefile/compose de chaque app).

```
Infra/
  bin/wt                 # dispatcher fin (parse args -> sous-commande)
  lib/
    profile.sh           # résolution app -> {repo, PROJECT_TYPE, base rule}
    git.sh               # fetch, worktree add/remove, garde-fous branche
    docker.sh            # compose up/down -p, statut, stats
    db.sh                # create/drop DB+user via docker exec MariaDB
    env.sh               # génération .docker/.env + patch .env.local
    registry.sh          # lecture/écriture registre JSON (jq)
    ui.sh                # log, plan/dry-run, tableaux
  etc/wt/apps.conf       # profils d'apps (v1 : les 5 Symfony)
  docs/…-design.md       # ce document
```

**Principes** : `set -euo pipefail` + `trap` de rollback ; une lib = un concern ; mode `--dry-run` qui **émet le plan sans agir** (testable sans docker) ; **une dépendance** : `jq` (présent). État hors repo : `~/.local/state/wt/` (registre + logs).

## 5. Surface CLI

| Commande | Rôle |
|---|---|
| `wt create <app> <slug> [--feature\|--hotfix] [--ticket KEY] [--dry-run] [--keep-on-error]` | branche+worktree, env docker, DB, up, install ; affiche l'URL |
| `wt list [--json]` | envs actifs : app, slug, branche, domaine, DB, état docker, disque |
| `wt destroy <app> <slug> [--yes] [--force] [--prune-branch] [--dry-run]` | teardown symétrique |
| `wt open <app> <slug>` | renvoie le chemin du worktree (cd/tmux/`claude`) |
| `wt doctor [--fix]` | réconcilie registre ↔ git ↔ docker ↔ DB ↔ `~/wt/`, signale/répare les orphelins |

## 6. Conventions de nommage

- `app` = clé repo (= nom tmux = base de `COMPOSE_PROJECT_NAME`).
- `slug` = ticket/branche assaini (DNS-safe minuscule pour domaine, `_` pour DB).
- projet docker `<app>-<slug>` · domaine `<app>-<slug>.docker.test` · DB+user `<app>_<slug>` · worktree `~/wt/<app>-<slug>` · branche `feature/<slug>` (base **develop**) ou `hotfix/<slug>` (base **main**).

## 7. Profils d'apps (`etc/wt/apps.conf`)

Une entrée par app : `repo_path`, `project_type` (symfony), `base_default` (develop), `compose_file` (.docker/docker-compose.yml), `install_target` (make install|défaut), `services` (indicatif, pour le garde-fou ressources). v1 = les 5 Symfony.

## 8. Flux `create`

1. Résolution du profil app (refuse inconnu / non-Symfony).
2. Calcul des noms (projet, domaine, DB, branche, path).
3. Préflight : slug libre (registre + `git worktree list`), DB inexistante, domaine libre ; **garde-fou RAM** (avertit si dispo < seuil).
4. Git : `fetch origin` ; `git worktree add -b <branche> ~/wt/<app>-<slug> origin/<base>` (checkout si branche existe = reprise).
5. Copie runtime : `.env.local`, `.env.test.local`, `.mcp.json` (pas vendor/node_modules).
6. Génération `.docker/.env` : `COMPOSE_PROJECT_NAME`, `COMPOSE_PROJECT_DOMAIN`, `APP_FOLDER` réécrits ; reste hérité.
7. Patch `.env.local` : `APP_URL=https://<domaine>` ; `DATABASE_URL` repointé (host conservé, db+user+mdp générés).
8. DB : `docker exec infra_mariadb_11_3` → `CREATE DATABASE/USER/GRANT` (mdp généré, stocké seulement dans le `.env.local` du worktree).
9. Docker : `docker compose -p <projet> up -d --build` ; Traefik route le domaine.
10. Install : `make install` si la cible existe, sinon `composer install` + `doctrine:migrations:migrate -n` + `fixtures:load -n` ; le container node fait `yarn install && encore dev --watch`.
11. Registre : ajoute l'entrée.
12. Sortie : URL + chemin + rappel session.

**Rollback auto** si échec après création de ressources (compose down, drop DB, rm worktree), sauf `--keep-on-error`. **Idempotent** (reprise d'un env partiel).

## 9. Flux `destroy`

1. **Plan affiché** (worktree, branche + alerte commits non poussés, projet docker, DB, disque). Confirmation requise (`--yes` non-interactif ; le bouton dashboard = confirmation).
2. **Garde-fous** : refuse si modifs non commitées / non poussées sans `--force` ; vérifie cible = worktree géré (`~/wt/` + registre), **jamais** un checkout principal.
3. `docker compose -p <projet> down -v`.
4. `DROP DATABASE` + `DROP USER` (uniquement ceux du worktree).
5. `git worktree remove --force` ; branche **conservée** par défaut (`--prune-branch` si mergée/poussée).
6. Retrait registre + rapport de libération.

## 10. Registre & `doctor`

`~/.local/state/wt/registry.json` — tableau d'entrées :
`{app, slug, project, path, branch, base, domain, db, created_at, status}` (pas de mot de passe DB).
`wt doctor` recoupe registre ↔ `git worktree list` ↔ `docker ps` ↔ liste DB ↔ dossiers `~/wt/` → détecte/répare orphelins (worktree sans docker, DB sans env, docker sans registre…). Source de vérité reconstructible.

## 11. Robustesse & sécurité

- **Périmètre de destruction strict** : ne touche jamais aux checkouts principaux, worktrees non gérés, ni à l'infra partagée (Traefik, serveur MariaDB, réseaux `mailer`/`databases`) ni aux DB d'autres apps.
- **Verrou par app** (lockfile) contre les `create`/`destroy` concurrents.
- **Logs** par opération : `~/.local/state/wt/logs/<projet>.log`.
- **Secrets** : mot de passe DB généré aléatoirement, présent uniquement dans le `.env.local` du worktree ; jamais dans le registre ni les logs.

## 12. Dépendances & accès

`bash`, `git`, `docker` (compose v2), `jq`, client `mysql` via `docker exec infra_mariadb_11_3` (creds admin lus dans `Infra/.env`). Tout présent sur le VPS.

## 13. Tests

- **`bats`** : parsing d'args, nommage/slug, génération `.docker/.env` + patch `.env.local`, plan `--dry-run` (assertions sur les commandes émises, **sans docker réel**), garde-fous `destroy` (refus checkout principal / branche sale).
- Un test d'intégration manuel documenté (création+destruction d'un env jetable sur une app Symfony).

## 14. Décisions ouvertes / suite

- Seuils exacts du garde-fou ressources (RAM libre mini avant `up`) — à caler à l'usage.
- **Sous-projet 2** : hook `SessionStart` (détection « travail en cours » → propose/crée un worktree) + skill `/worktree-env`.
- **Sous-projet 3** : dashboard web (Traefik + Tailscale + basic auth) : liste, aller/supprimer, métriques RAM/CPU/disque.
- **v2** : support PrestaShop (`uspiecesautos`, `direkto`).
