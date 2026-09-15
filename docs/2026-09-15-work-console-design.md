# `work` + garde d'écriture + console (design)

Date : 2026-09-15 · Statut : design validé en conversation (en attente de relecture de la spec) · Remplace : moteur `wt`, hook/skill `worktree-env`, dashboard `wt` (specs du 2026-09-05).

## 1. Contexte & objectif

Les worktrees (`wt`) isolaient chaque ticket dans un checkout + une stack Docker + une base + un domaine. Résultat jugé trop lourd : bazar sur le VPS, remontage Docker, logique complexe. On les **abandonne complètement**.

Nouveau modèle : **un seul checkout et une seule stack par projet**. La concurrence entre sessions Claude (tmux, remote) ne se règle plus par isolation mais par un **verrou d'écriture** : une seule session écrit dans un projet à la fois ; toutes les autres peuvent lire, analyser la prod, ou écrire dans un *autre* projet.

Workflow cible (validé) :
1. pull de la base ;
2. création de la branche ;
3. travail ;
4. ouverture de la PR, puis **retour immédiat sur la base** ;
5. Simon merge la PR ;
6. Simon dit « c'est mergé » → pull de la base + suppression de la branche locale.

Le tout est complété par une **console** (ex-dashboard) en lecture seule : sessions lancées, ce qu'elles exécutent, état des projets, diagnostic du VPS.

## 2. Périmètre

Quatre lots, livrés dans l'ordre, **une branche + une PR Infra par lot** :

| Lot | Contenu |
|---|---|
| 1 | Démontage de `wt` (inventaire, refus si travail non sauvegardé, retrait) |
| 2 | CLI `work` + hook garde d'écriture + hook SessionStart + skill `work` + migration des repos |
| 3 | Console v1 lecture seule (renommage, collecteur en tâche de fond, vues Projets/Sessions/Docker/Diagnostics) |
| 4 | Journal d'activité alimenté par les hooks Claude + statut temps réel des sessions dans la console |

**Hors périmètre :** alertes (n8n/Telegram), historisation des métriques, toute action déclenchée depuis la console (arrêt de session, libération de verrou), worktrees sous quelque forme que ce soit.

## 3. Lot 1 — Démontage de `wt`

### 3.1 Prérequis manuel
Les environnements `wt` encore enregistrés contiennent peut-être du travail. Au 2026-09-15 : `bifacto-doc-sa-org-funnel` a **5 fichiers non commités** (PortfolioController + test + 3 traductions). Ce travail est commité et poussé sur sa branche (action sortante → validation de Simon) **avant** toute exécution du démontage.

### 3.2 `bin/wt-decommission`
Script one-shot. **Simulation par défaut** ; `--apply` pour exécuter.

**Inventaire** (affiché dans les deux modes) :
- environnements du registre `~/.local/state/wt/registry.json` (conteneurs, base, chemin) ;
- **tous** les worktrees git secondaires des repos sous `~/Project/*/*` et `~/Project/*` (`git worktree list --porcelain`), y compris ceux créés hors de `wt` (ex. `Diplam09/doc-session-cleanup`) ;
- dossiers restants sous `~/wt/` ;
- lignes `.mcp.json` dans les fichiers `.worktreeinclude` ;
- hook `SessionStart` pointant sur `wt-session-hook` et skill `~/.claude/skills/worktree-env`.

**Contrôle de sauvegarde** : pour chaque worktree secondaire, statut `SAUF` ou `À RISQUE` :
- `À RISQUE` si `git status --porcelain` non vide, **ou** si des commits de la branche ne sont sur aucune branche distante (`git log --branches --not --remotes` limité à la branche) ;
- `--apply` **refuse de tout faire** (exit 1, aucune suppression) tant qu'un worktree est `À RISQUE`, et liste les coupables.

**Retrait** (`--apply`, uniquement si tout est `SAUF`) :
1. pour chaque env du registre : `docker compose down` (profils inclus, même logique que `wt destroy`), puis `DROP DATABASE` dans le conteneur enregistré ;
2. `git worktree remove` puis `git worktree prune` dans chaque repo ;
3. suppression de `~/wt/` (s'il est vide après l'étape 2 ; sinon arrêt et rapport) et de `~/.local/state/wt/` ;
4. retrait de la ligne `.mcp.json` des `.worktreeinclude` (fichier supprimé s'il devient vide) ;
5. `~/.claude/settings.json` : sauvegarde `settings.json.bak-<date>`, retrait via `jq` de l'entrée `SessionStart` wt-session-hook ;
6. suppression du lien `~/.claude/skills/worktree-env`.

Chaque étape est idempotente : relancer le script après un échec partiel reprend là où il s'était arrêté.

### 3.3 Retrait du code (même PR, commit suivant l'exécution)
Suppression de : `bin/wt`, `bin/wt-hook-install`, `bin/wt-session-hook`, `lib/` (fichiers wt), `etc/wt/`, `skills/worktree-env/`, tests bats associés, `docs/wt-README.md`, `docs/wt-hook-README.md`, puis `bin/wt-decommission` lui-même.
Le dashboard actuel est **amputé a minima** pour rester fonctionnel jusqu'au lot 3 : retrait de la section worktrees, de `server/destroy.php`, de la route `POST /api/worktrees/*/destroy` et des lignes worktree du CSV.

## 4. Lot 2 — `work`, garde d'écriture, skill

### 4.1 Configuration des projets : `etc/work/projects.conf`
Format : `nom|repo|base_feature|base_hotfix|forge`
- `base_feature` = `develop` si `origin/develop` existe, sinon `main` ; `base_hotfix` = `main` (ou `master` si c'est la branche par défaut du repo) ;
- `forge` = `github` ou `gitlab` (d'après l'URL `origin`).

Rempli à l'implémentation d'après l'état réel des remotes. État relevé le 2026-09-15 : 15 repos applicatifs sous `~/Project/*/*` + `Infra` + `_nowia` ; forges GitHub sauf `stream.consotrust.com` (gitlab.agena3000.com) et `services-rest.bifacto.com` (gitlab.com) ; pas de `develop` sur `parisrental.com`, `hermes-webui`, `services-rest.bifacto.com`. Un repo absent de la liste n'est pas protégé par la garde.

### 4.2 État d'un projet : `<git-common-dir>/claude-work.json`
Invisible pour git, jamais versionné. Écritures sérialisées par `flock` sur `<git-common-dir>/claude-work.lock`. Fichier absent ≡ état `free` sans PR en attente.

```json
{
  "state": "free | active",
  "ticket": "GEL-123",
  "branch": "feature/GEL-123-export-pdf",
  "base": "develop",
  "owner_session": "59ea2850-…",
  "started_at": "2026-09-15T19:30:00Z",
  "pending_prs": [
    {"ticket": "GEL-120", "branch": "feature/GEL-120-…", "base": "develop",
     "number": 42, "url": "https://github.com/…/pull/42", "opened_at": "…", "parked": false}
  ]
}
```
Les champs `ticket`, `branch`, `base`, `owner_session`, `started_at` n'existent que si `state = active`. Une branche mise de côté (`park`) figure dans `pending_prs` avec `parked: true` et `number: null`.

L'identité de session est lue dans `CLAUDE_CODE_SESSION_ID` (exporté par Claude Code dans l'environnement des commandes Bash, identique au `session_id` reçu par les hooks). Hors de Claude (terminal humain), elle vaut `human:<user>@<tty>`.

### 4.3 CLI `bin/work`
Toutes les commandes s'exécutent dans le repo du `cwd` (résolu par plus long préfixe dans `projects.conf`) ; erreur explicite sinon.

| Commande | Préconditions (sinon exit ≠ 0, rien n'est modifié) | Effet |
|---|---|---|
| `work start <KEY> [--hotfix] [--slug S]` | `free` ; arbre propre (fichiers ignorés exclus) ; branche inexistante en local et sur origin | `fetch` ; `checkout <base>` ; `pull --ff-only` ; `checkout -b feature/<KEY>-<slug>` (ou `hotfix/…`) ; état `active` au nom de la session. **Avertit** (sans bloquer) si `pending_prs` non vide : le nouveau travail ne contiendra pas ces PR. |
| `work pr [--title T --body-file F]` | `active`, possédé par la session ; sur `branch` ; arbre propre | `push -u origin <branch>` ; si aucune PR n'existe pour la branche : GitHub → `gh pr create --base <base>` ; GitLab → affiche l'URL de création de MR. Puis `checkout <base>` ; `pull --ff-only` ; ticket déplacé dans `pending_prs` ; état `free`. |
| `work merged [KEY]` | la PR visée est dans `pending_prs` (KEY facultatif s'il n'y en a qu'une) ; arbre propre | GitHub : `gh pr view <branch> --json state` doit valoir `MERGED`, sinon refus. GitLab (pas de CLI) : exige `--confirmed`. Puis, si l'état est `free` : `checkout <base>` + `pull --ff-only` (sinon simple `fetch`, la base sera pullée au prochain `start`) ; `branch -D <branch>` (forcé car les merges squash sont invisibles pour `-d`, sûr car le merge est vérifié) ; retrait de `pending_prs`. |
| `work resume <KEY>` | `free` ; arbre propre ; KEY dans `pending_prs` | `fetch` ; `checkout <branch>` ; `pull --ff-only` si la branche distante existe ; état `active` au nom de la session ; retrait de `pending_prs`. Sert aux corrections après relecture et à la reprise d'un travail mis de côté. |
| `work park` | `active`, possédé par la session | `add -A` ; `commit -m "wip: <KEY> parked"` (s'il y a des changements) ; `push -u` ; `checkout <base>` ; `pull --ff-only` ; ticket dans `pending_prs` avec `parked: true` ; état `free`. Sert au hotfix urgent pendant une feature. Jamais de `stash`. |
| `work adopt <KEY>` | `free` ; branche courante ≠ base | État `active` sur la branche courante au nom de la session, sans toucher git (migration des travaux existants). |
| `work takeover` | `active` | Réattribue `owner_session` à la session courante. Affiche l'ancien propriétaire et s'il est encore vivant. Uniquement sur demande explicite de Simon. |
| `work status [--all] [--json]` | — | État du projet courant (ou de tous) : état, ticket, branche, propriétaire (vivant/mort), PR en attente, fichiers modifiés, dérive (voir §5.3). |

Règles transverses : aucune mention de Claude/IA dans les commits et PR produits ; `git push` et création de PR sont des actions sortantes : le skill demande validation avant `work pr` et `work park`.

### 4.4 Hook garde d'écriture : `bin/work-guard`
`PreToolUse`, matcher `Edit|MultiEdit|Write|NotebookEdit|Bash`. Remplace `~/.claude/hooks/guard-branch-clean.sh` (retiré de `settings.json` : la création de branche est désormais une écriture comme une autre et `work start` vérifie l'arbre propre).

**1. Cibles de l'action**
- `Edit`/`MultiEdit`/`Write`/`NotebookEdit` : `tool_input.file_path` (ou `notebook_path`).
- `Bash` : la commande est découpée sur `&&`, `||`, `;`, `|`, `$(…)` ; `bash -c`/`sh -c` et `docker compose exec|run <svc> …` sont analysés récursivement ; un segment `cd <dir>` met à jour le répertoire effectif. Cibles = répertoire effectif + tout argument chemin absolu.
- Une cible hors des repos de `projects.conf`, ou ignorée par git (`git check-ignore`), n'est pas concernée.

**2. Est-ce une écriture ?** (Edit/Write/NotebookEdit : toujours.) Pour Bash, un segment écrit s'il correspond à :
- `git` + `commit|checkout|switch|merge|rebase|reset|revert|restore|stash|pull|push|cherry-pick|am|apply|clean|rm|mv|tag <nom>|branch <args autres que listage>` ;
- `rm|mv|cp|touch|mkdir|rmdir|ln|chmod|chown|truncate|patch|tee|install`, `sed -i`, `perl -i` ;
- redirection `>` / `>>` vers un chemin hors `/tmp`, `/dev` ;
- `composer install|update|require|remove|dump-autoload`, `npm|yarn|pnpm install|ci|add|remove|update|run build` ;
- `make` (toute cible) ;
- `php bin/console doctrine:*|make:*|cache:*|assets:install|importmap:*`, `phpunit`, `vendor/bin/phpunit`, `bin/phpunit`, `vendor/bin/pest` ;
- `docker compose up|down|build|restart|rm` lancé dans un repo.

**Toujours autorisés** : `bin/work …` (il porte ses propres contrôles), `git fetch|status|log|diff|show|branch` (listage), et toute commande non listée. Limite assumée : une écriture exotique non listée passe.

**3. Décision** pour chaque repo cible touché en écriture :
| État du projet | Décision |
|---|---|
| `free` | **Bloqué** : « aucun ticket démarré sur <projet> — `work start <KEY>` ou `work resume <KEY>` ». |
| `active`, propriétaire = session | Autorisé si la branche courante = `branch` ; sinon **bloqué** (« la branche courante n'est pas celle du ticket »). |
| `active`, autre propriétaire | **Bloqué** : « écriture tenue par la session <id court> (<tmux>, ticket, depuis <durée>) — lecture seule autorisée ». Si le propriétaire est mort (pas de `~/.claude/sessions/*.json` vivant pour cet id) : le message le signale et propose `work takeover`. |

Blocage = exit 2 + message sur stderr (contrat PreToolUse). **Fail-open** : toute erreur interne (jq absent, JSON illisible, config introuvable) → exit 0 et trace dans le journal (lot 4) ; un garde-fou cassé ne doit pas paralyser les sessions. Échappatoire globale : `WORK_GUARD=off` dans l'environnement du processus Claude. Budget : < 100 ms par appel.

### 4.5 Hook `bin/work-session-hook` (SessionStart)
Remplace `wt-session-hook`. Si le `cwd` est dans un projet géré, injecte en `additionalContext` : état, ticket et propriétaire (« toi » / autre session / mort), PR en attente, dérive détectée. Rappel si `free` ou autre propriétaire : « lecture seule tant que `work start` n'est pas fait ». Silencieux hors projet géré. Toujours exit 0.

### 4.6 Skill `work` (remplace `start-ticket` et `worktree-env`)
Déclencheurs : « on démarre <KEY> », « ouvre la PR », « c'est mergé », « reprends <KEY> », « mets de côté », « état des projets ».
- **Démarrer** : lit le ticket si une source est configurée (Jira via `.claude/gitflow.json`, comme `start-ticket` aujourd'hui), propose feature/hotfix et le slug, **fait confirmer**, puis `work start`.
- **Ouvrir la PR** : rédige titre et description (sans mention d'IA), **demande validation**, puis `work pr`.
- **« c'est mergé »** : `work merged` et rapporte le résultat (y compris un refus si la PR n'est pas mergée).
- **Reprendre / mettre de côté** : `work resume` / `work park` (validation avant push).
- **État** : `work status --all`.

`~/.claude/skills/start-ticket` est supprimé une fois le skill `work` en place ; `.claude/gitflow.json` de GEL reste lu.

### 4.7 Migration des repos existants (fin de lot 2, avec Simon)
`work status --all` liste les projets en dérive (modifiés ou hors base sans état). Pour chacun, décision de Simon au cas par cas : `work adopt <KEY>` (vrai ticket en cours), commit + PR, ou abandon des changements. État relevé le 2026-09-15 : `stream.consotrust.com` (feature, 6 fichiers), `direkto.fr` (feature, 24), `asteria.immo` (main, 8), `parisrental.com` (feature, 1), `auth.bifacto.com` (hotfix, 1), `bifacto.com` (hotfix, 1), `myprojekt.fr` (hotfix, 1), `uspiecesautos.com` (main, 1), `hermes-webui` (master, 2), `Infra` (main, 1 : route Traefik NOWIA non commitée).

## 5. Lot 3 — Console v1 (lecture seule)

### 5.1 Renommage
| Avant | Après |
|---|---|
| `dashboard/` | `console/` |
| `bin/wt-metrics` | `bin/console-collector` |
| `bin/wt-dash-install`, `make dash-deploy` | `bin/console-install`, `make console-deploy` |
| unit `wt-dashboard` | units `console-web` + `console-collector` |
| `worktree.docker.test`, route/middleware Traefik `wt-dashboard*` | `console.docker.test`, `console*` |
| `certs/wt-dashboard.htpasswd`, `~/.wt-dashboard-credential` | `certs/console.htpasswd`, `~/.console-credential` |

La route Traefik NOWIA (actuellement non commitée) référence `wt-dashboard.htpasswd` : la référence est mise à jour dans la même opération. Bascule : 1 `docker restart infra_traefik`.

### 5.2 Architecture : le travail lourd hors de la page
```
console-collector (systemd, boucle) ──▶ ~/.local/state/console/snapshot.json
work (lot 2)                        ──▶ <git-common-dir>/claude-work.json
hooks (lot 4)                       ──▶ ~/.local/state/console/events-AAAA-MM-JJ.jsonl
console-web (php -S) : lit uniquement ces fichiers ──▶ UI (rafraîchie toutes les 2 s)
```
Constat à l'origine : le collecteur actuel prend 4,5 s (21 s à froid, dont `docker stats` 2,5 s) alors que la page rafraîchit toutes les 3 s et que `php -S` ne traite qu'une requête à la fois.

**Collecteur** : boucle bash, une section = une fonction avec sa cadence ; chaque section écrit son propre fichier (écriture atomique `tmp` + `mv`), assemblés dans `snapshot.json` avec un `collected_at` par section.

| Section | Cadence | Source |
|---|---|---|
| `system` | 2 s | `/proc/meminfo`, `/proc/loadavg`, PSI `cpu`/`memory`/`io` |
| `sessions` | 5 s | `~/.claude/sessions/*.json` (pid vivant uniquement) |
| `projects` | 10 s | `projects.conf` + `claude-work.json` + git local (sans fetch) |
| `prs` | 5 min | `gh pr view` pour chaque `pending_prs` GitHub |
| `docker` | 15 s | `docker stats --no-stream` + labels compose |
| `diagnostics` | 15 s | calculs sur les sections ci-dessus + sources propres (§5.5) |
| `disk` | 60 s | `df` ; `docker system df` toutes les 10 min |

**API** : `GET /api/snapshot` (renvoie le fichier ; ajoute `stale: true` si une section a plus de 3 fois son âge de cadence) ; `GET /api/snapshot.csv` (CSV actuel adapté aux nouvelles sections, protection contre l'injection de formules conservée). Aucune route d'écriture.

### 5.3 Vue Projets
Une carte par projet de `projects.conf` : état (`libre` / `ticket en cours` / `N PR en attente`), ticket, branche, propriétaire (id court, session tmux, vivant/mort), fichiers modifiés, avance/retard sur origin (dernier fetch connu).
**Dérives signalées** :
- **« PR mergée, base pas resynchronisée »** : une entrée de `pending_prs` est `MERGED` côté GitHub → « dis “c'est mergé” » ;
- **projet modifié ou hors base sans état `active`** (écriture hors workflow) ;
- **verrou tenu par une session morte**.

### 5.4 Vue Sessions
Source : `~/.claude/sessions/*.json` dont le pid est vivant. Pour chaque session : projet (plus long préfixe du `cwd`), type (`interactive`/remote), session tmux (remontée des pid parents jusqu'à un `pane_pid` de `tmux list-panes -a`), âge, **RAM de l'arbre de processus** (pid + descendants, dont les serveurs MCP locaux), ticket tenu le cas échéant. Les sessions internes (`cwd` sous `~/.claude-mem/`) sont regroupées dans une ligne « système ». Les fichiers de sessions mortes sont ignorés (pas supprimés). En lot 3, le statut d'activité se limite à « vivante » ; le lot 4 ajoute le statut temps réel.

### 5.5 Vue Docker & diagnostics
**Docker** : conteneurs groupés par label `com.docker.compose.project`, rattachés à un projet via `com.docker.compose.project.working_dir` ; CPU, RAM, état, nombre de redémarrages.

**Diagnostics** : chaque détecteur produit `{id, niveau: ok|warn|crit, titre, détail, action suggérée}`.
| Détecteur | warn | crit |
|---|---|---|
| RAM disponible | < 20 % | < 10 % |
| Swap utilisé | > 50 % | > 80 % |
| PSI mémoire `some avg60` | > 10 | > 25 |
| PSI io `some avg60` | > 20 | > 40 |
| Disque (par point de montage) | > 85 % | > 95 % |
| Processus tués par manque de mémoire (24 h, `journalctl -k`) | ≥ 1 | — |
| Conteneur `unhealthy` ou redémarré depuis le dernier passage | ≥ 1 | redémarrages ≥ 3 en 15 min |
| Unités systemd utilisateur en échec | ≥ 1 | — |
| Serveur MCP local lancé en plusieurs exemplaires (même ligne de commande) | > 3 | > 10 |
| Verrou tenu par une session morte | ≥ 1 | — |

Une source indisponible (ex. `journalctl -k` sans droits) produit un diagnostic `warn` « source indisponible », jamais une erreur de collecte.

### 5.6 UI
Ordre : vitals (hero) → diagnostics non `ok` → Projets → Sessions → Docker → Disques. Conserve l'acquis de la refonte (recherche instantanée, repli mémorisé, grille responsive, thème clair/sombre). Aucune action d'écriture. Accès inchangé : Tailscale + basicauth.

## 6. Lot 4 — Journal d'activité

### 6.1 Hook `bin/console-hook`
Un seul script, déclaré sur `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`, `SessionEnd`. Ajoute **une ligne JSON** à `~/.local/state/console/events-<date UTC>.jsonl` :
```json
{"ts":"…","event":"PreToolUse","session":"59ea2850-…","cwd":"…","project":"lagestionenligne",
 "tool":"Bash","tool_use_id":"…","summary":"make test","result":null}
```
- `summary` : Bash → commande ; Edit/Write → chemin du fichier ; Notification → message ; autres → vide. **Le texte des prompts n'est jamais enregistré.** `result` (PostToolUse) : `ok` / `error`.
- **Masquage** avant écriture : valeurs de `password|passwd|secret|token|api[_-]?key=…`, identifiants dans les URL (`://user:pass@`), `Bearer …`, chaînes hex/base64 de plus de 32 caractères. Puis troncature à 300 caractères.
- La garde d'écriture (lot 2) écrit ses décisions de blocage dans le même journal (`event: "guard.block"`, avec le motif).
- Écriture par un seul `>>` d'une ligne < 4 Ko (atomique) ; budget < 50 ms ; **toujours exit 0**, aucune sortie sur stdout.
- Rétention : le collecteur supprime les fichiers de plus de 7 jours.

### 6.2 Statut temps réel (collecteur, section `sessions`)
Déduit du dernier événement de chaque session (lecture de la fin du fichier du jour et de la veille) :
| Dernier événement | Statut affiché |
|---|---|
| `PreToolUse` sans `PostToolUse` correspondant (appariement par `tool_use_id`, sinon dernier `PreToolUse` de la session) | 🟢 exécute `<summary>` depuis <durée> |
| `Notification` | 🟡 attend ta réponse depuis <durée> |
| `UserPromptSubmit`, `PostToolUse`, `SubagentStop` | 💭 travaille |
| `Stop` | ⚪ au repos depuis <durée> |
| `SessionEnd` ou pid mort | terminée (masquée) |

Nouveau diagnostic : **session au repos depuis plus de 2 h avec plus de 300 Mo** d'arbre de processus → `warn` « session inactive coûteuse ».

### 6.3 UI
Badge de statut sur chaque session ; panneau « Activité » avec les 200 derniers événements (toutes sessions), filtrable par projet, blocages de la garde mis en évidence.

## 7. Tests

Suite **bats**, comme l'existant :
- `work` : repos git de test créés dans un dossier temporaire avec un remote nu local ; `gh` simulé par un stub dans le `PATH` ; un test par commande et par précondition refusée ; `flock` concurrent (deux `start` simultanés → un seul réussit).
- `work-guard` : fixtures JSON d'entrée hook ; table de cas du classifieur Bash (écriture / lecture / récursif / `cd` / chemins absolus / ignorés) ; les trois décisions ; fail-open sur JSON invalide.
- `wt-decommission` : faux registre + worktrees de test ; refus si `À RISQUE` ; idempotence ; simulation sans aucun effet.
- Collecteur : chaque section sur fixtures (`/proc` simulé via variables d'environnement, sorties `docker`/`gh`/`tmux` stubées) ; écriture atomique ; détection `stale`.
- `console-hook` : format de ligne, masquage, troncature, absence de prompt, exit 0 même en erreur ; mesure de durée.
- Console : tests API existants adaptés + smoke test du rendu.

## 8. Dépendances

`git`, `jq`, `flock`, `gh` (authentifié, compte Nowwis), `tmux`, `docker`, `php-cli` 8.3, `bats` 1.10 — tous présents sur l'hôte. `glab` absent : GitLab géré sans CLI (§4.3). Claude Code ≥ version exposant `CLAUDE_CODE_SESSION_ID` et les hooks listés en §6.1.
