# Modèle de site

Point de départ d'un site branché sur le socle (voir `docs/CONTRACT.md`) : le projet ne déclare
que ses services applicatifs (nginx, php, nodejs) et rejoint les réseaux `traefik`,
`databases` et `mailer`. Pas de base, de proxy ni de serveur de mail à lui.

Un seul jeu de fichiers pour quatre types, choisis par `PROJECT_TYPE` dans `.docker/.env` :

| Type | Services (`COMPOSE_PROFILES`) | Racine web | Config nginx |
|---|---|---|---|
| `html` | nginx seul (vide) | `public/` | `.docker/nginx/html.conf` |
| `symfony` | nginx, php, nodejs (`php,assets`) | `public/` | `.docker/nginx/symfony.conf` |
| `wordpress` | nginx, php (`php`) | racine du projet | `.docker/nginx/wordpress.conf` |
| `prestashop` | nginx, php (`php`) | racine du projet | `.docker/nginx/prestashop.conf` |

PrestaShop : version 9 uniquement (testé avec 9.2). Son archive contient un `Makefile` de
développement qui écrase celui du modèle : le renommer (`Makefile.prestashop`) avant de
remettre celui-ci.

## Démarrer un site

```bash
cp -r templates/site ~/Project/<Client>/<domaine-de-prod>
cd ~/Project/<Client>/<domaine-de-prod>
cp .docker/.env.example .docker/.env
# PROJECT_TYPE, COMPOSE_PROFILES, COMPOSE_PROJECT_NAME, COMPOSE_PROJECT_DOMAIN,
# COMPOSE_PRODUCTION_DOMAIN, PROD_WWW_ALIAS
make upbuild
```

Le site répond sur `https://<COMPOSE_PROJECT_NAME>.docker.test` (certificat mkcert du socle).
`make help` liste les cibles communes et celles du type (`.docker/make/<type>.mk`).

## Choix du modèle

- **PHP** : une seule image, version **figée dans `.docker/php/Dockerfile`** (`FROM php:8.4-fpm`),
  jamais dans `.docker/.env` (voir `docs/DECISIONS.md`, 2026-10-21). Changer de version = une PR.
  Extensions communes aux trois frameworks. Xdebug par `ENABLE_XDEBUG=1` puis `make upbuild`.
- **HTTPS vu par PHP** : Traefik termine le TLS ; nginx transmet `HTTPS=on` à PHP d'après
  `X-Forwarded-Proto`. Sans cela, WordPress et PrestaShop redirigent vers `http://`.
- **Assets Symfony** : le conteneur nodejs installe les dépendances puis reste inactif. Pas de
  watch résident (640 à 865 Mio par stack) ; `make yarn-dev` ou `make yarn-build` à la demande.
- **Journaux nginx** : sur la sortie du conteneur (`make logs`), pas dans le dépôt.
- **Prod** : `make ENV=prod …` utilise `docker-compose.prod.yml` (Let's Encrypt,
  `security-headers@file`, redémarrage automatique). `PROD_WWW_ALIAS=1` ajoute la redirection
  `www.` → domaine, **pour un domaine racine seulement** : `www.<sous-domaine>` n'a pas de DNS
  et ferait échouer le certificat en boucle.
- **Worker Messenger** (Symfony, prod) : `COMPOSE_PROFILES=php,worker`.

## Déploiement

`.github/workflows/deploy.yml` : `main` → environnement GitHub `prod`, `develop` → `preprod`,
sur un runner self-hosted installé sur le serveur (labels `self-hosted` + `prod`/`preprod`).
Le job fait `git reset --hard origin/<branche>` dans `vars.VPS_DEPLOY_DIR`, lance
`make ENV=prod deploy`, puis vérifie `vars.SITE_URL`. Le répertoire de prod est un clone git
avec son propre `.docker/.env`. Installer le runner est une opération serveur, hors modèle.
