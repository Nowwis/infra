# infra — socle d'hébergement partagé

Un reverse proxy, une base par moteur, un capteur de mails, une console SQL : le socle sur
lequel se branchent toutes les applications Docker d'un hôte, en local comme en production.
Un seul dépôt, un seul `compose.yml`, déployé à l'identique sur chaque machine ; ce qui varie
tient dans un `.env` et un dossier de configuration par environnement.

| Service | Conteneur | Rôle | Exposé |
|---|---|---|---|
| Traefik v2.11 | `infra_traefik` | Reverse proxy, TLS (mkcert en local, Let's Encrypt en prod), redirection 80→443 | 80, 443 |
| MySQL 8.0 | `infra_mysql_8_0` | Base partagée par les applications | réseau `databases` |
| MariaDB 11.3 | `infra_mariadb_11_3` | Second moteur, **profil optionnel** | réseau `databases` |
| phpMyAdmin | `infra_phpmyadmin` | Console SQL des deux moteurs, basic-auth dédié | `$PMA_DOMAIN` |
| Mailpit | `infra_mailer` | Capteur SMTP + interface web | `infra_mailer:1025`, `$MAILPIT_DOMAIN` |

Les applications ne déclarent **que** leurs services, rejoignent les réseaux externes `traefik`,
`databases`, `mailer`, et se publient par labels. Le contrat complet : [`docs/CONTRACT.md`](docs/CONTRACT.md).

## Démarrer

**En local** (poste ou machine de développement, domaines `*.docker.test`) :

```bash
git clone <url> ~/infra && cd ~/infra
cp .env.example .env            # ENV=local ; renseigner MYSQL_ROOT_PASSWORD et TRAEFIK_PHPMYADMIN_USERS
make networks                   # une fois : réseaux traefik, databases, mailer
make certs                      # une fois : certificat mkcert *.docker.test (mkcert -install au préalable)
make up                         # = make check + docker compose up -d
```

Résoudre `*.docker.test` vers la machine (fichier hosts, dnsmasq, ou DNS interne). Mailpit sur
`https://mailer.docker.test`, phpMyAdmin sur `https://phpmyadmin.docker.test`.

**Sur un serveur** (`ENV=prod`, Let's Encrypt, écoute publique) : suivre
[`docs/RUNBOOK-deploy.md`](docs/RUNBOOK-deploy.md). En résumé : `.env` complet, `make networks`,
`make up`, puis à chaque mise à jour `make deploy`.

`make check` refuse de démarrer tant qu'une variable obligatoire manque, qu'un hash contient
un `$` non doublé, ou que le dossier de configuration dynamique de l'environnement est absent.
Ces trois erreurs ont chacune déjà mis des sites en 404 ; c'est pour cela que la vérification
n'est pas optionnelle.

## Documentation

| Document | Pour |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Comprendre : réseaux, Traefik statique/dynamique, TLS, moteurs, conventions de nommage |
| [`docs/COMMANDS.md`](docs/COMMANDS.md) | Toutes les commandes et leurs combinaisons, par situation |
| [`docs/CONTRACT.md`](docs/CONTRACT.md) | Brancher une application : compose minimal, labels, variables, check-list |
| [`docs/RUNBOOK-deploy.md`](docs/RUNBOOK-deploy.md) | Installer un hôte, mettre à jour, revenir en arrière |
| [`docs/RUNBOOK-incident.md`](docs/RUNBOOK-incident.md) | Diagnostiquer : 404 partout, certificat, hash tronqué, logs |
| [`docs/RUNBOOK-backup-restore.md`](docs/RUNBOOK-backup-restore.md) | Contrôle hebdomadaire de restauration, restauration manuelle, ce qui reste à produire |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Ce qui est exposé, derrière quoi, où vivent les secrets |
| [`docs/HOSTS.md`](docs/HOSTS.md) | Gabarit de fiche par hôte (l'inventaire réel reste privé) |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Pourquoi c'est fait ainsi |
| [`CHANGELOG.md`](CHANGELOG.md) | Ce qui change, et si une action serveur est requise |

## Arborescence

```
compose.yml                      les cinq services, un seul fichier pour tous les hôtes
.env.example                     toutes les variables, commentées
Makefile                         networks · certs · check · up · down · ps · logs · traefik-config · deploy · test
bin/infra-check                  la vérification pré-déploiement (make check)
configuration/traefik2/
  config/traefik.local.yaml      config statique locale (dashboard ouvert, pas d'ACME)
  config/traefik.prod.yaml       config statique prod (ACME, journal d'accès JSON)
  config/dynamic/local/          certificat mkcert, exemples de routes vers l'hôte
  config/dynamic/prod/           middlewares partagés (en-têtes de sécurité, opt-in)
  certs/                         mkcert (gitignoré)      logs/  journal d'accès (gitignoré)
  rotate-logs.sh                 rotation du journal d'accès, sans logrotate, via cron
configuration/mysql_8_0/conf.d/  surcharges MySQL (vide par défaut)
datas/                           données des moteurs (gitignoré)      letsencrypt/  acme.json (gitignoré)
ops/backup-check/                contrôle hebdomadaire de restauration (scripts, unité systemd, env exemple)
ops/sync-db-names.sh             renommage de bases par dump/reload, non destructif par défaut
tests/                           bats (make test)
docs/
```

## Prérequis

Docker Engine avec Compose v2, `bash`, `curl`, `jq`. En local : `mkcert`. Pour les tests : `bats`.
Pour le contrôle de restauration : `ssh` vers les serveurs contrôlés, `python3` (construction du
JSON d'alerte).

## Licence

À définir avant publication (voir `docs/DECISIONS.md`).
