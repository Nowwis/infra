# Dashboard `worktree.docker.test` — observabilité + pilotage (design)

Date : 2026-09-05 · Statut : design validé (en attente de relecture) · Portée : **sous-projet 3/3** · Dépend de : SP1 (moteur `wt`), SP2 (hook/skill — pas requis au runtime du dashboard).

## 1. Contexte & objectif

Un panneau web pour **voir et piloter** ce qui est difficilement visible sur le VPS autour de ce workflow : RAM/CPU/swap/load, containers docker par projet, worktree-envs, **sessions Claude en cours**, disque — avec export et quelques actions sûres. C'est l'analyse du début de session rendue vivante. Le dashboard est un **client** du moteur `wt` (aucune logique dupliquée).

## 2. Périmètre (v1)

**Dans le périmètre :** observabilité complète + **actions sûres** :
- Métriques : système, docker (par projet compose), worktrees (+ disque), sessions Claude, disque global. Export JSON/CSV.
- Actions : **supprimer un worktree-env** (confirmation → `wt destroy … --yes`), **ouvrir l'URL de l'app** (`https://<app>-<slug>.docker.test`).

**Hors périmètre (v2) :** tuer/arrêter une session Claude ou une stack docker depuis l'UI ; graphes historisés (v1 = valeurs instantanées + petites sparklines en mémoire client).

## 3. Composants

**a. Collecteurs** — `bin/wt-metrics <section|all>` (bash, hôte, sortie JSON) :
- `system` : `free`/`/proc/meminfo` (RAM/swap), `/proc/pressure/*` (PSI), load, nb cœurs.
- `docker` : `docker stats --no-stream --format '{{json .}}'` + `docker ps` → par container : nom, projet compose (label `com.docker.compose.project`), cpu%, mem.
- `worktrees` : `wt list --json` + `du -sb ~/wt/<name>`.
- `sessions` : `ps` des process `claude` / `remote-control` / backends SDK → pid, nom, modèle, RSS, cpu%, âge.
- `disk` : `df`.
Fail-safe : chaque section dégrade en `{}`/`[]` si sa commande échoue ; `wt-metrics all` renvoie un objet agrégé.

**b. Backend** — service PHP léger (`php -S`) sur l'**hôte**, en `systemd --user` (redémarre seul). API JSON, endpoints **fixes** (aucune exécution arbitraire) :
- `GET /api/metrics` → agrégat (`wt-metrics all`), cache ~2 s.
- `GET /api/metrics.csv` → export aplati.
- `POST /api/worktrees/{project}/destroy` → valide que `{project}` existe dans le registre `wt`, puis `wt destroy <app> <slug> --yes` ; renvoie le résultat. Toute autre entrée → 400/404.
- Sert les assets statiques du front.
Placement hôte car il doit voir les **process hôte** (sessions Claude), docker et les métriques système — inaccessibles à un container sans privilèges lourds.

**c. Frontend** — HTML/JS statique **sans dépendance lourde** (jauges/barres CSS, sparklines maison), thème clair/sombre, responsive. Poll `/api/metrics` ~3 s. Sections : système (jauges RAM/swap/CPU/load) · docker par projet · worktrees (bouton *supprimer* + lien *ouvrir l'app*) · sessions Claude (RSS/cpu%/âge) · disque. Bouton *export*.

**d. Exposition/install** — `bin/wt-dash-install [--uninstall]` : pose l'unit `systemd --user` (backend sur un port local dédié, bind sur l'IP atteignable) + une entrée **Traefik file-provider** dans `configuration/traefik2/config/dynamic_conf.local.yaml` : router `Host(\`worktree.docker.test\`)` → service `http://<hôte>:<port>` + middleware **basicauth**, sur l'entrypoint websecure. L'adresse d'atteinte hôte depuis Traefik (IP Tailscale `100.75.44.109` probable ; à **confirmer dans le plan** via l'inspection réseau) et le rechargement Traefik font partie de la tâche d'install.

## 4. Sécurité

Accès **Tailscale uniquement** + **basicauth** Traefik (comme phpMyAdmin/monitoring). L'unique action mutante (`destroy`) valide contre le registre puis délègue à `wt destroy` (qui refuse déjà hors `~/wt/` et un arbre sale). Pas d'exec de commande arbitraire ; endpoints fixes. Le backend tourne en `--user` (pas root) ; il lit les métriques et appelle `wt`/`docker` avec les droits de l'utilisateur `webadmin`.

## 5. Tests

- **Collecteurs** (`bin/wt-metrics`) : `bats` sur fixtures (sortie `free`/`docker stats`/`ps`/`df` simulées via un `PATH` de test) → forme JSON attendue, fail-safe par section.
- **Backend** : test de l'endpoint `destroy` (validation : projet inconnu → refus ; projet connu → appelle `wt destroy` — `wt` stubé) ; `/api/metrics` renvoie du JSON valide. Via `php -S` local + curl, ou en testant la couche routage isolément.
- **Front** : manuel (checklist dans le README).

## 6. Décisions ouvertes / suite

- Confirmer dans le plan l'**adresse hôte atteignable** par le container Traefik (IP Tailscale vs gateway du réseau traefik) et la forme exacte de l'entrée `dynamic_conf.local.yaml` + le rechargement.
- Port local du backend (ex. 8899) et nom de l'unit systemd.
- v2 : contrôle des sessions/stacks depuis l'UI ; historisation des métriques.
