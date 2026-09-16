# Console dev (`console.docker.test`)

Console d'observation **en lecture seule** du VPS : vitals, diagnostics, état des projets
`work`, sessions Claude, conteneurs Docker et disques. La page ne lance aucune commande :
un collecteur en tâche de fond écrit un instantané, la page le lit.

Elle remplace le dashboard `worktree.docker.test`, retiré avec les worktrees le 2026-09-15
(voir `docs/2026-09-15-work-console-design.md`).

## Architecture

```
bin/console-collector (systemd console-collector)
    ├─ sections → ~/.local/state/console/sections/<nom>.json   (écriture atomique)
    └─ assemble → ~/.local/state/console/snapshot.json
console/server (php -S, systemd console-web) : lit l'instantané, ne lance rien
console/public : rafraîchit /api/snapshot toutes les 2 s
```

| Section | Cadence | Contenu |
|---|---|---|
| `system` | 2 s | mémoire, swap, charge, PSI (cpu/mémoire/io), compteur `oom_kill` |
| `sessions` | 5 s | sessions Claude vivantes : projet, tmux, RAM de l'arbre de processus, MCP, ticket tenu, MCP orphelins |
| `projects` | 10 s | `work status --all` + état GitHub des PR en attente |
| `docker` | 15 s | conteneurs : état, projet, CPU, mémoire, redémarrages, santé |
| `diagnostics` | 15 s | constats `warn`/`crit` calculés sur les autres sections |
| `disk` | 60 s | `df` par point de montage |
| `prs` | 5 min, en tâche de fond | `gh pr view` des PR en attente (GitHub seulement) |
| `docker_df` | 10 min, en tâche de fond | `docker system df` (≈ 11 s) |

Chaque section est indépendante : une source indisponible donne une valeur par défaut et un
diagnostic « source indisponible », jamais une erreur globale.

## Diagnostics

RAM disponible (< 20 % / < 10 %), swap (> 50 % / > 80 %), PSI mémoire (> 10 / > 25), PSI io
(> 20 / > 40), disque par montage (> 85 % / > 95 %), hausse du compteur OOM sur 24 h,
conteneurs `unhealthy` ou qui redémarrent (≥ 3 → critique), unités systemd utilisateur en
échec (hors `init.scope`, toujours en échec sur cet hôte), serveurs MCP orphelins (> 3 / > 10),
verrou `work` tenu par une session terminée.

`journalctl -k` étant réservé au groupe `adm`, les kills OOM se lisent dans `/proc/vmstat`.

## API

- `GET /api/snapshot` — l'instantané ; chaque section porte `age_s` et `stale` (âge > 3 × cadence).
  Collecteur arrêté ou instantané illisible → `{"generated_at":null,"sections":{},"missing":true}`.
- `GET /api/snapshot.csv` — le même contenu aplati (protection contre l'injection de formules).
- Aucune route d'écriture.

## Variables

| Variable | Défaut | Rôle |
|---|---|---|
| `CONSOLE_STATE` | `~/.local/state/console` | sections et instantané |
| `CONSOLE_SNAPSHOT` | `$CONSOLE_STATE/snapshot.json` | instantané lu par l'API |
| `CONSOLE_PROC` | `/proc` | source des vitals (simulée dans les tests) |
| `CONSOLE_SESSIONS_DIR` | `~/.claude/sessions` | fichiers de session Claude |
| `WORK_CONF` | `etc/work/projects.conf` | projets, pour rattacher conteneurs et sessions |
| `CONSOLE_PORT` / `CONSOLE_BIND` | `8899` / IP Tailscale | écoute de `php -S` |
| `CONSOLE_USER` / `CONSOLE_PASSWORD` | `admin` / — | secret basic-auth (hashé à l'install) |

## Installation

```bash
cp console/console.env.example console/console.env   # puis renseigner CONSOLE_PASSWORD
make console-deploy      # pull + unités systemd + secret + redémarrage
```

`bin/console-install` écrit les unités `console-web` et `console-collector` et le secret
`configuration/traefik2/certs/console.htpasswd`. Il ne touche jamais la route Traefik, qui est
versionnée. `bin/console-install --uninstall` retire unités et secret.

Une mise à jour de code (UI, collecteur) ne demande qu'un `git pull` : le service web sert les
fichiers en direct. Seul le collecteur doit être redémarré s'il a changé.

## Bascule depuis l'ancien dashboard (à faire avec Simon)

1. `systemctl --user disable --now wt-dashboard.service` et suppression de son unité.
2. `make console-deploy` (unités + secret `console.htpasswd`).
3. Route Traefik, dans `configuration/traefik2/config/dynamic_conf.local.yaml` : renommer
   `wt-dashboard` en `console`, `Host(worktree.docker.test)` en `Host(console.docker.test)`, et
   faire pointer le middleware sur `/etc/certs/console.htpasswd`. **La route NOWIA du même
   fichier référence le même secret** : mettre à jour les deux références dans la même
   opération, puis commiter ce fichier (aujourd'hui modifié hors git).
4. `docker restart infra_traefik`.
5. Vérifier : 401 sans authentification, 200 avec, et `/api/snapshot` qui renvoie les sections.

## Sécurité

Ne jamais exposer le service publiquement (`CONSOLE_BIND=0.0.0.0`) : l'authentification est
assurée par Traefik, pas par `php -S`. L'API ne fait que lire un fichier JSON local, mais elle
révèle l'état de la machine et des projets.

## Journal d'activité

Un hook unique (`bin/console-hook`) est branché sur huit événements Claude Code —
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`,
`SubagentStop`, `SessionEnd` — et ajoute **une ligne JSON** par événement dans
`~/.local/state/console/events-<date UTC>.jsonl` :

```json
{"ts":"2026-09-16T10:31:02Z","event":"PreToolUse","session":"b4681ad6-…","cwd":"/home/webadmin/Project/Diplam09/doc.bifacto.com",
 "project":"bifacto-doc","tool":"Bash","tool_use_id":"toolu_…","summary":"make test","result":null}
```

**Ce qui n'est jamais enregistré** : le texte des prompts. Un `UserPromptSubmit` ne laisse que
l'événement, sans contenu. Les secrets sont masqués avant écriture (mots de passe, jetons,
`Bearer …`, identifiants dans les URL, chaînes de plus de 32 caractères), et chaque résumé est
tronqué à 300 caractères.

La garde d'écriture y trace aussi ses refus (`"event":"guard.block"`), ce qui permet de voir
depuis la console qu'une session a tenté d'écrire sans ticket.

**Coût** : environ 13 ms par appel d'outil (bash + un seul `jq`), après les ~41 ms de la garde.
Le hook sort toujours en succès et n'écrit rien sur la sortie standard : un journal cassé ne doit
jamais bloquer un outil.

**Rétention** : 7 jours, purge faite par le collecteur d'après la date du nom de fichier.

### Ce que le collecteur en déduit

- Section `activity` (cadence 5 s) : les 200 derniers événements, du plus récent au plus ancien.
- Section `sessions` : un statut par session vivante —
  `executing` (un outil est lancé, sans résultat reçu), `waiting` (une notification attend une
  réponse), `working` (un résultat vient d'arriver), `idle` (après `Stop`), `unknown` (pas encore
  d'événement) — avec le détail, l'ancienneté et le dernier blocage éventuel de la garde.
