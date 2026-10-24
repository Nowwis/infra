# Changelog

Une entrée par changement livré sur `main`. Chaque entrée dit si une **action serveur** est
requise : nouvelle variable `.env`, `make traefik-config`, cron, ou rien.

## Non publié

### Modifié
- MySQL passe en **8.4 LTS** (`mysql:8.4`, testé en 8.4.13) : la 8.0 est en fin de vie. Mise à
  niveau en place au premier démarrage, **sans retour arrière en place**. Le conteneur garde son nom
  `infra_mysql_8_0` et ses chemins `datas/mysql_8_0/` (contrat des applications). `make check` refuse
  un changement de série non confirmé (`MYSQL_UPGRADE_CONFIRMED=1`) et toute descente de série ;
  `restore-test.sh` restaure par défaut sur `mysql:8.4`. **Action serveur** : procédure complète
  `docs/RUNBOOK-deploy.md` §4 (comptes `mysql_native_password`, dump, copie à froid, montée) ;
  `make deploy` s'arrête sur le contrôle MySQL tant que l'hôte n'est pas monté, c'est voulu.
- `make deploy` s'arrête si `make check` échoue (il recréait quand même le reverse proxy) et met à
  jour `gatus` quand le profil est actif. `make check` lit le `.env` désigné par `INFRA_ENV_FILE` aussi
  pour `docker compose config`. **Action serveur** : aucune.
- Traefik passe en **v3.7** (`traefik:v3.7`) : la 2.11 n'a plus de correctifs de sécurité depuis le
  2026-09-07. `aliasHeadersStrategy: delete` sur `web` et `websecure` (en-têtes imitant un autre en-tête,
  lus comme tel par PHP/nginx). **Action serveur** : `git pull`, puis `docker compose pull reverse-proxy
  && docker compose up -d --no-deps reverse-proxy`. Côté applications : plus de `Host(`a`, `b`)` à plusieurs
  arguments, à réécrire dans les applications avant la montée.

### Sécurité
- phpMyAdmin passe sur l'image officielle `phpmyadmin:5.2` (PHP 8.3.36, correctif PHP2Shell) ;
  `phpmyadmin/phpmyadmin` n'est plus mise à jour. **Action serveur** : `git pull`, puis
  `docker compose pull phpmyadmin && docker compose up -d --no-deps phpmyadmin`.

### Ajouté
- `templates/site/` : modèle de site branché sur le socle, un seul jeu de fichiers pour
  Symfony, WordPress, PrestaShop 9 et HTML statique (`PROJECT_TYPE`, services par
  `COMPOSE_PROFILES`), prod avec alias `www` optionnel (domaine racine seulement), workflow de
  déploiement par runner self-hosted. WordPress : `wp-config.local.php` lu dans l'environnement
  (`WP_ENVIRONMENT_TYPE=local`, `WP_DEBUG_LOG`, `DISABLE_WP_CRON` optionnel), msmtp et wp-cli dans
  l'image PHP, `mail()` vers Mailpit en local seulement, cibles `db-pull`, `files-pull` et
  `cache-purge` paramétrées (`REMOTE`, `REMOTE_PROD`, `PROD_URL`, `LOCAL_URL`, préfixe des tables),
  repli nginx sur `index.php` pour `wp-sitemap.xml` et `robots.txt`. Conteneur nodejs déclaré
  sain seulement après son installation de démarrage (marqueur posé en fin d'installation). Validé
  par une installation réelle de chaque type ; 22 tests bats (`tests/site-template.bats`). Action serveur : aucune.
- **Surveillance Gatus** (profil optionnel `gatus`, `infra_gatus`, `twinproduction/gatus:v5.37.0`) :
  config fournie par l'hôte hors du dépôt (`GATUS_CONFIG_DIR`, montée en lecture seule), exemple neutre
  dans `configuration/gatus/example/`, alertes Telegram, page d'état derrière `gatus-auth`. `make check`
  valide variables, dossier et config (chargée par l'image) quand le profil est actif ; 15 tests bats de
  plus. `.env.example` : `COMPOSE_PROFILES`, `GATUS_*`, `TRAEFIK_GATUS_USERS`. **Action serveur** : rien
  sur les hôtes qui n'activent pas le profil ; sinon dossier de config, variables `.env`, puis `make up`.
- Socle complet : `compose.yml` (Traefik 2.11, MySQL 8.0, MariaDB 11.3 sous profil, phpMyAdmin,
  Mailpit), `.env.example` exhaustif, `Makefile` (`networks`, `certs`, `check`, `up`, `down`,
  `ps`, `logs`, `traefik-config`, `deploy`, `test`).
- `bin/infra-check` : vérification pré-déploiement, 16 tests bats.
- Configuration Traefik statique `local`/`prod`, dynamique en dossier, middlewares
  `security-headers` et `security-headers-idp` en opt-in.
- `configuration/traefik2/rotate-logs.sh` : rotation du journal d'accès sans logrotate.
- `ops/backup-check` : contrôle hebdomadaire de restauration, unité systemd templatée, canaux
  d'alerte e-mail (API ou SMTP), webhook, commande locale.
- `ops/sync-db-names.sh` : renommage de bases par dump/reload.
- Documentation : README, ARCHITECTURE, COMMANDS, CONTRACT, RUNBOOK-deploy, RUNBOOK-incident,
  RUNBOOK-backup-restore, SECURITY, HOSTS (gabarit), DECISIONS.

### Action serveur requise à la première installation depuis ce dépôt
- `.env` : toutes les variables de `.env.example`, dont `TRAEFIK_PHPMYADMIN_USERS` (nouvelle,
  obligatoire) et `TRAEFIK_BIND`.
- `make networks` si les réseaux n'existent pas.
- Le dossier `configuration/traefik2/config/dynamic/<ENV>/` remplace tout ancien fichier
  `dynamic_conf.<ENV>.yaml` : `make traefik-config` après le premier `git pull`.
- Les unités `restore-check@` remplacent d'anciennes unités au nom différent : désactiver les
  anciennes, poser les nouvelles, recopier la configuration dans `backup.env.<hote>`.
