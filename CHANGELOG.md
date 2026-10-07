# Changelog

Une entrée par changement livré sur `main`. Chaque entrée dit si une **action serveur** est
requise : nouvelle variable `.env`, `make traefik-config`, cron, ou rien.

## Non publié

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
