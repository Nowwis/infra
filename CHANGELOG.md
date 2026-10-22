# Changelog

Une entrée par changement livré sur `main`. Chaque entrée dit si une **action serveur** est
requise : nouvelle variable `.env`, `make traefik-config`, cron, ou rien.

## Non publié

### Modifié
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
