# `work` + garde d'écriture + console (design)

Date : 2026-09-15 · Statut : design validé en conversation (en attente de relecture de la spec) · Remplace : moteur `wt`, hook/skill `worktree-env`, dashboard `wt` (specs du 2026-09-05).

## 1. Contexte & objectif

Les worktrees (`wt`) isolaient chaque ticket dans un checkout + une stack Docker + une base + un domaine. Résultat jugé trop lourd : bazar sur le VPS, remontage Docker, logique complexe. On les **abandonne complètement**.

Nouveau modèle : **un seul checkout et une seule stack par projet**. La concurrence entre sessions Claude (tmux, remote) ne se règle plus par isolation mais par un **verrou d'écriture** : une seule session écrit dans un projet à la fois ; toutes les autres peuvent lire, analyser la prod, ou écrire dans un *autre* projet.

Workflow cible (validé) :
1. pull de **main et develop, toujours** ;
2. création de la branche : **feature tirée de develop, hotfix tirée de main** ;
3. travail ;
4. ouverture de la PR, puis **retour immédiat sur main** ;
5. Simon merge la PR ;
6. *(facultatif)* Simon dit « c'est mergé » → pull de main et develop + suppression de la branche locale. Si Simon ne le dit pas, le ménage est fait au `work start` suivant.

Au repos, un projet est donc **toujours sur main, arbre propre**.

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
Les environnements `wt` encore enregistrés contiennent peut-être du travail. Au 2026-09-15 : `bifacto-doc-sa-org-funnel` (branche `feature/sa-org-funnel`) a **5 fichiers non commités** (PortfolioController + test + 3 traductions) **et 8 commits jamais poussés**. Ce travail est commité et poussé sur sa branche (action sortante → validation de Simon) **avant** toute exécution du démontage.

### 3.2 `bin/wt-decommission`
Script one-shot. **Simulation par défaut** ; `--apply` pour exécuter.

**Inventaire** (affiché dans les deux modes) :
- environnements du registre `~/.local/state/wt/registry.json` (conteneurs, base, chemin) ;
- **tous** les worktrees git secondaires des repos sous `~/Project/*/*` et `~/Project/*` (`git worktree list --porcelain`), y compris ceux créés hors de `wt` (ex. `Diplam09/doc-session-cleanup`) ;
- dossiers restants sous `~/wt/` ;
- lignes `.mcp.json` dans les fichiers `.worktreeinclude` ;
- hook `SessionStart` pointant sur `wt-session-hook` et skill `~/.claude/skills/worktree-env`.

**Contrôle de sauvegarde** : pour chaque worktree secondaire, un statut :
- `MANQUANT` : dossier disparu (git le marque `prunable`) → simple `prune` ;
- `EN USAGE` : le `cwd` d'une session Claude vivante (`~/.claude/sessions/*.json`, pid vivant) est dans ce dossier — cas des worktrees `.claude/worktrees/bridge-*` créés par les sessions distantes ;
- `À RISQUE` : `git status --porcelain` non vide, **ou** commits de `HEAD` absents de toute branche distante (`git rev-list --count HEAD --not --remotes`) ;
- `SAUF` : sinon.

Un dossier sous `~/wt/` qui n'est pas un worktree connu est `INCONNU`.
`--apply` **refuse de tout faire** (exit 1, aucune suppression) tant qu'il existe un élément `À RISQUE`, `EN USAGE` ou `INCONNU`, et les liste.

**Retrait** (`--apply`, sans élément bloquant) :
1. pour chaque env du registre : `wt destroy <app> <slug> --yes` (réutilise la logique existante : `docker compose down` profils inclus, `DROP DATABASE`, retrait du worktree et du registre) ;
2. `git worktree remove` (sans `--force`) des autres worktrees présents, suppression du dossier parent `.claude/worktrees` s'il devient vide, puis `git worktree prune` dans chaque repo ;
3. suppression de `~/wt/` (qui doit être vide) et de `~/.local/state/wt/` ;
4. suppression des `.worktreeinclude` **non versionnés** (tous le sont au 2026-09-15 : ils ne servaient qu'aux worktrees) et de leur ligne dans `.git/info/exclude` ; un `.worktreeinclude` versionné est laissé et signalé ;
5. `~/.claude/settings.json` : sauvegarde `settings.json.bak-<date>` si le hook est présent, puis `bin/wt-hook-install --uninstall` (retire l'entrée `SessionStart` wt-session-hook et le lien `~/.claude/skills/worktree-env`).

Chaque étape est idempotente : relancer le script après un échec partiel reprend là où il s'était arrêté.

### 3.3 Retrait du code (même PR, commit suivant l'exécution)
Suppression de : `bin/wt`, `bin/wt-hook-install`, `bin/wt-session-hook`, `bin/wt-decommission`, `lib/` (entièrement : tous ses fichiers relèvent de `wt`), `etc/wt/`, `skills/worktree-env/`, `tests/fixtures/` (utilisées uniquement par des tests `wt`), les tests bats propres à `wt` (moteur, hook, skill, destroy du dashboard, décommission), `docs/wt-README.md`, `docs/wt-hook-README.md`. Les specs et plans du 2026-09-05 restent comme historique.
Le dashboard actuel est **amputé a minima** pour rester fonctionnel jusqu'au lot 3 : retrait de la section worktrees (collecteur `wt-metrics`, HTML, JS, CSS), de `server/destroy.php`, de la route `POST /api/worktrees/*/destroy` et des lignes worktree du CSV ; `docs/wt-dashboard-README.md` est mis à jour en conséquence.

## 4. Lot 2 — `work`, garde d'écriture, skill

### 4.1 Configuration des projets : `etc/work/projects.conf`
Format : `nom|repo|main|develop|forge`
- `main` = branche principale du repo (`main`, ou `master` si c'est son nom) : base des hotfix et **branche de repos** ;
- `develop` = `develop` si `origin/develop` existe, sinon vide : base des features (repli sur `main` si vide) ;
- `forge` = `github` ou `gitlab` (d'après l'URL `origin`).

Rempli d'après les références distantes réelles (relevé du 2026-09-15) : **14 projets** — `Infra` (main seul) et 13 repos applicatifs avec main + develop ; forge GitHub sauf `stream.consotrust.com` (gitlab.agena3000.com). **Exclus** : `AgentIA/hermes-webui` (repo tiers), `_nowia` (pas de remote), `Diplam09/services-rest.bifacto.com` (GitLab tiers, référence `origin/main?` cassée). Un repo absent de la liste n'est pas protégé par la garde.

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

**Synchro des bases** (utilisée par `start`, `pr`, `merged`, `park`) : `fetch origin` puis mise à jour en avance rapide **de main et de develop** — `pull --ff-only` pour la branche actuellement checkoutée, `fetch origin <b>:<b>` pour l'autre. Une divergence arrête la commande (exit ≠ 0, message).

**Ménage automatique** (utilisé par `start`, rendant l'étape 6 facultative) : pour chaque entrée non `parked` de `pending_prs` sur GitHub dont `gh pr view` renvoie `MERGED`, suppression de la branche locale (`branch -D`) et retrait de `pending_prs`, avec une ligne de rapport.

| Commande | Préconditions (sinon exit ≠ 0, rien n'est modifié) | Effet |
|---|---|---|
| `work start <KEY> [--hotfix] [--slug S]` | `free` ; arbre propre (fichiers ignorés exclus) ; branche inexistante en local et sur origin | ménage automatique ; `checkout main` ; synchro des bases ; `checkout -b feature/<KEY>-<slug> develop` (ou `hotfix/<KEY>-<slug> main`) ; état `active` au nom de la session. **Avertit** (sans bloquer) s'il reste des `pending_prs` : le nouveau travail ne contiendra pas ces PR. |
| `work pr [--title T --body-file F]` | `active`, possédé par la session ; sur `branch` ; arbre propre | `push -u origin <branch>` ; si aucune PR n'existe pour la branche : GitHub → `gh pr create --base <base>` (develop pour une feature, main pour un hotfix) ; GitLab → affiche l'URL de création de MR. Puis `checkout main` ; synchro des bases ; ticket déplacé dans `pending_prs` ; état `free`. |
| `work merged [KEY]` | *(facultatif)* la PR visée est dans `pending_prs` (KEY facultatif s'il n'y en a qu'une) | GitHub : `gh pr view <branch> --json state` doit valoir `MERGED`, sinon refus. GitLab (pas de CLI) : exige `--confirmed`. Puis synchro des bases ; `branch -D <branch>` (forcé car les merges squash sont invisibles pour `-d`, sûr car le merge est vérifié) ; retrait de `pending_prs`. Ne change jamais la branche checkoutée. |
| `work resume <KEY>` | `free` ; arbre propre ; KEY dans `pending_prs` | `fetch` ; `checkout <branch>` ; `pull --ff-only` si la branche distante existe ; état `active` au nom de la session ; retrait de `pending_prs`. Sert aux corrections après relecture et à la reprise d'un travail mis de côté. |
| `work park` | `active`, possédé par la session | `add -A` ; `commit -m "wip: <KEY> parked"` (s'il y a des changements) ; `push -u` ; `checkout main` ; synchro des bases ; ticket dans `pending_prs` avec `parked: true` ; état `free`. Sert au hotfix urgent pendant une feature. Jamais de `stash`. |
| `work adopt <KEY>` | `free` ; branche courante ≠ base | État `active` sur la branche courante au nom de la session, sans toucher git (migration des travaux existants). |
| `work takeover` | `active` | Réattribue `owner_session` à la session courante. Affiche l'ancien propriétaire et s'il est encore vivant. Uniquement sur demande explicite de Simon. |
| `work sync [--tidy]` | arbre propre si la branche courante est une base | Synchro des bases sans ticket : `fetch` puis avance rapide de main et develop, sans toucher à la branche courante. `--tidy` : si la branche courante n'est pas une base, qu'aucun ticket n'est actif, que l'arbre est propre et que sa PR GitHub est `MERGED` → retour sur main et suppression de la branche locale. Ajoutée le 2026-09-16 : la garde bloque `git pull`/`checkout` hors ticket, or mettre les bases à jour reste une opération de routine. |
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
`work status --all` liste les projets en dérive (modifiés, ou hors de main, sans état `active`). Pour chacun, décision de Simon au cas par cas : `work adopt <KEY>` (vrai ticket en cours), commit + PR, ou abandon des changements. État relevé le 2026-09-15 : `stream.consotrust.com` (feature, 6 fichiers), `direkto.fr` (feature, 24), `asteria.immo` (main, 8), `parisrental.com` (feature, 1), `auth.bifacto.com` (hotfix, 1), `bifacto.com` (hotfix, 1), `myprojekt.fr` (hotfix, 1), `uspiecesautos.com` (main, 1), `hermes-webui` (master, 2), `Infra` (main, 1 : route Traefik NOWIA non commitée).

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

Le renommage de la route Traefik (`dynamic_conf.local.yaml`) se fait **au déploiement, avec Simon**, pas dans la PR : ce fichier porte la route NOWIA non commitée, qui référence `wt-dashboard.htpasswd` et doit passer à `console.htpasswd` dans la même opération. Bascule : arrêt de `wt-dashboard`, route mise à jour, 1 `docker restart infra_traefik`, vérification 401 sans auth / 200 avec.

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
| `prs` | 5 min, en tâche de fond | `gh pr view` pour chaque `pending_prs` GitHub |
| `docker` | 15 s | `docker stats --no-stream` + labels compose |
| `diagnostics` | 15 s | calculs sur les sections ci-dessus + sources propres (§5.5) |
| `disk` | 60 s | `df` |
| `docker_df` | 600 s, en tâche de fond | `docker system df` (≈ 11 s) |

**API** : `GET /api/snapshot` (renvoie le fichier ; ajoute `stale: true` si une section a plus de 3 fois son âge de cadence) ; `GET /api/snapshot.csv` (CSV actuel adapté aux nouvelles sections, protection contre l'injection de formules conservée). Aucune route d'écriture.

### 5.3 Vue Projets
Une carte par projet de `projects.conf` : état (`libre` / `ticket en cours` / `N PR en attente`), ticket, branche, propriétaire (id court, session tmux, vivant/mort), fichiers modifiés, avance/retard sur origin (dernier fetch connu).
**Dérives signalées** :
- **branche locale mergée** (information, pas une alerte) : une entrée de `pending_prs` est `MERGED` côté GitHub → nettoyée au prochain `work start` ou par « c'est mergé » ;
- **projet modifié, ou hors de main, sans état `active`** (écriture hors workflow) ;
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
| Processus tués par manque de mémoire (hausse du compteur `oom_kill` de `/proc/vmstat` sur 24 h ; `journalctl -k` est interdit sans le groupe `adm`) | ≥ 1 | — |
| Conteneur `unhealthy` ou redémarré depuis le dernier passage | ≥ 1 | redémarrages ≥ 3 en 15 min |
| Unités systemd utilisateur en échec (hors `init.scope`, toujours en échec sur l'hôte) | ≥ 1 | — |
| Serveurs MCP orphelins : processus `mcp` hors de l'arbre de toute session vivante (un serveur par session est normal) | > 3 | > 10 |
| Verrou tenu par une session morte | ≥ 1 | — |

Une source indisponible (ex. docker absent, section jamais collectée) produit un diagnostic `warn` « source indisponible », jamais une erreur de collecte.

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
