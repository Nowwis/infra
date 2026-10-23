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

## WordPress

Le cœur n'est pas versionné ; `wp-config.php` non plus (copie locale, ignorée par git).

```bash
make upbuild
make core WP_VERSION=6.8 WP_LOCALE=fr_FR   # vide = dernière version, en_US
make wp-config                             # .docker/wp-config.local.php → wp-config.php
make db-create                             # base et compte WORDPRESS_DB_* sur le socle
```

- **Configuration locale** (`.docker/wp-config.local.php`) : base lue dans l'environnement du
  conteneur php (`WORDPRESS_DB_*`, `WORDPRESS_TABLE_PREFIX` de `.docker/.env`),
  `WP_ENVIRONMENT_TYPE=local`, `WP_DEBUG_LOG` (`wp-content/debug.log`), WP-Cron coupé par
  `WORDPRESS_DISABLE_CRON=1`.
- **Mails** : l'image PHP embarque msmtp ; en local seulement, `.docker/php/91-local-mail.ini`
  envoie `mail()` dans le Mailpit du socle (`https://mailer.docker.test`). La prod ne monte pas
  ce fichier.
- **wp-cli** est dans l'image : `make wp A="plugin list"`.
- **Copie depuis le serveur** : `make db-pull` (dump en flux, search-replace de `PROD_URL` vers
  `LOCAL_URL`, désactivation de `WP_LOCAL_DEACTIVATE`, purge des caches) et `make files-pull`
  (uploads, langues). Lecture seule côté serveur. Variables vides par défaut, à poser dans
  `.docker/.env` : `REMOTE` (alias SSH), `REMOTE_PROD` (chemin), `PROD_URL`, `LOCAL_URL` (vide =
  `https://$COMPOSE_PROJECT_DOMAIN`), `WORDPRESS_TABLE_PREFIX`. Détail en tête de
  `.docker/make/wordpress.mk`.
- **Après tout import de base**, purger les caches (`make cache-purge`, fait par `db-pull`) : les
  constructeurs de pages gardent du CSS et des rendus générés avec les URL du serveur.
- **Ne jamais rendre une page par PHP CLI sur un serveur pour la « tester »** (`php index.php`,
  `wp eval`…) : les constructeurs de pages écrivent alors un cache calculé hors requête HTTP,
  cassé, servi ensuite aux visiteurs. Tester par `curl` sur l'URL.
- **nginx** : `wp-sitemap.xml` et `robots.txt` sont générés par WordPress ; la config retombe sur
  `index.php` quand le fichier n'existe pas. Le sitemap demande des permaliens autres que
  « simples » (`make wp A="rewrite structure /%postname%/"`), sinon WordPress redirige.

## Déploiement

`.github/workflows/deploy.yml` : `main` → environnement GitHub `prod`, `develop` → `preprod`,
sur un runner self-hosted installé sur le serveur (labels `self-hosted` + `prod`/`preprod`).
Le job fait `git reset --hard origin/<branche>` dans `vars.VPS_DEPLOY_DIR`, lance
`make ENV=prod deploy`, puis vérifie `vars.SITE_URL`. Le répertoire de prod est un clone git
avec son propre `.docker/.env`. Installer le runner est une opération serveur, hors modèle.
