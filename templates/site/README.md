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
  et ferait échouer le certificat en boucle. `TRAEFIK_ALIAS_RULE` remplace cette règle par une
  liste d'hôtes libre (autres domaines redirigés), `TRAEFIK_AUTH_USERS` ajoute une basic auth
  (environnement de développement, voir « Déploiement »).
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

Le modèle ne fournit pas de déploiement : pas de workflow CI, pas de script. L'outil de
déploiement de l'hôte l'ajoute au moment de créer le dépôt du site (workflow, script, accès au
serveur), parce que la façon d'atteindre un serveur dépend de l'hôte, pas du site.

Ce qu'un déploiement attend du modèle, quel que soit l'outil :

- **Un dossier par environnement sur le serveur** (prod, et dev s'il existe), qui reçoit le code
  du dépôt et garde **son propre `.docker/.env`**, jamais versionné ni écrasé par le déploiement
  (comme `vendor/`, `var/`, les uploads, `wp-config.php` : à exclure de toute synchronisation).
  Le `.env` de prod : `COMPOSE_PROJECT_NAME`, `COMPOSE_PRODUCTION_DOMAIN`, `PROD_WWW_ALIAS` ou
  `TRAEFIK_ALIAS_RULE`, les profils (`worker` pour Symfony), les identifiants de l'application.
- **Une commande** lancée dans ce dossier après la mise à jour du code : `make ENV=prod deploy`
  (cible du type dans `.docker/make/<type>.mk` : reconstruction et redémarrage, plus dépendances,
  migrations et cache pour Symfony, cache pour PrestaShop). Avant, rafraîchir les images de base
  (`docker compose --env-file .docker/.env -f .docker/docker-compose.prod.yml pull
  --ignore-buildable` puis `build --pull`), sinon un correctif publié en amont n'arrive jamais.
- **Le socle démarré sur l'hôte** (réseaux `traefik`, `databases`, `mailer`, résolveur `le`,
  middleware `security-headers@file`) et le DNS du domaine (et des alias) pointant sur l'hôte.

### Environnement de développement sur le même hôte

Même fichiers, second dossier, autre `.docker/.env` : seules ces lignes changent.

```dotenv
COMPOSE_PROJECT_NAME=site-dev            # distinct de la prod : conteneurs, routeurs, image
COMPOSE_PRODUCTION_DOMAIN=dev.example.com
PROD_WWW_ALIAS=0                         # jamais www pour un sous-domaine
TRAEFIK_AUTH_USERS=qa:$$2y$$05$$…        # htpasswd -nbB qa <mot de passe>, chaque $ doublé
```

`TRAEFIK_AUTH_USERS` vide (la prod) : aucun middleware d'authentification n'est attaché. La base
du dev est une base distincte de celle de la prod (autres identifiants dans son `.env`).

## Ce qui est propre au projet

Les fichiers du modèle restent **identiques** dans chaque dépôt (`.docker/`, `Makefile`) : un écart se corrige dans
le modèle, pas dans la copie. Ce qu'un projet ajoute vit dans des fichiers facultatifs, chargés s'ils existent :

| Fichier | Rôle |
|---|---|
| `.docker/docker-compose.project.yml` | services locaux en plus (worker Messenger, broker, outil de dev), ou complément d'un service commun |
| `.docker/docker-compose.prod.project.yml` | idem en prod (`ENV=prod`) |
| `.docker/make/project.mk` | cibles `make` du projet |

Un service ajouté rejoint les mêmes réseaux que les services communs (`project_network`, et `databases` / `mailer`
s'il en a besoin), sans base ni serveur de mail à lui.
