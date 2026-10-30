# Modèle de site

Point de départ d'un site branché sur le socle (voir `docs/CONTRACT.md`) : le projet ne déclare
que ses services applicatifs (nginx, php, nodejs) et rejoint les réseaux `traefik`,
`databases` et `mailer`. Pas de base, de proxy ni de serveur de mail à lui.

Un seul jeu de fichiers pour cinq types, choisis par `PROJECT_TYPE` dans `.docker/.env` :

| Type | Services (`COMPOSE_PROFILES`) | Racine web | Config nginx |
|---|---|---|---|
| `html` | nginx seul (vide) | `public/` | `.docker/nginx/html.conf` |
| `symfony` | nginx, php, nodejs (`php,assets`) | `public/` | `.docker/nginx/symfony.conf` |
| `wordpress` | nginx, php (`php`) | racine du projet | `.docker/nginx/wordpress.conf` |
| `prestashop` | nginx, php (`php`) | racine du projet | `.docker/nginx/prestashop.conf` |
| `php` | nginx, php (`php`) | racine du projet | `.docker/nginx/php.conf` |

`php` : PHP natif sans framework (tout `.php` existant s'exécute, le reste retombe sur `index.php`).
Les types servis depuis la racine du projet (`wordpress`, `prestashop`, `php`) refusent `/deploy/`,
`/Makefile`, `/composer.json`, `/composer.lock`, les `*.md` à la racine et les chemins cachés
(`/.docker/`, `/.git/`…) ; WordPress aussi `readme.html`, `license.txt`, `wp-config-sample.php`,
`php` aussi `/vendor/`.

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
  Extensions communes aux trois frameworks (dont `soap`). Xdebug par `ENABLE_XDEBUG=1` puis `make upbuild`.
  Compléments facultatifs (wkhtmltopdf, pcov, paquets et extensions PECL) : voir « Ce qui est propre au projet ».
- **PHP ini** : `.docker/php/90-extra-config.ini` (php et worker) ; erreurs dans le journal
  (`log_errors = On`), jamais dans la page (`display_errors = Off`), `max_input_vars = 10000`.
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
- **Symfony, seul le contrôleur frontal s'exécute** : `/index.php` passe à PHP, tout autre `.php` répond
  404 (un `.php` déposé dans `public/uploads` n'est jamais exécuté).
- **Symfony, maintenance** : si `var/maintenance.flag` existe, nginx répond 503 à toute requête, avec
  `public/maintenance.html` s'il existe (page autonome : CSS et images en ligne, les autres fichiers
  répondent 503 aussi), sinon la page 503 de nginx. Le flag est posé et retiré par le projet (cibles
  `maintenance-on` / `maintenance-off` de son `project.mk`, voir plus bas) ; nginx le lit à chaque requête,
  sans redémarrage.
- **`make ENV=test init-dev`** recrée la base de test (chaque commande console reçoit `--env=$(ENV)`) ;
  sans `ENV`, la base de dev.

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
| `.docker/docker-compose.project.yml` | services locaux en plus (worker Messenger, broker, outil de dev), ou complément d'un service commun (args de l'image PHP, ini, règles nginx) |
| `.docker/docker-compose.prod.project.yml` | idem en prod (`ENV=prod`) ; à tenir cohérent avec le fichier local |
| `.docker/make/project.mk` | réglages (`SF_*` de `deploy.mk`…), cibles `make` du projet, remplacement d'une cible du modèle ; lu **avant** les cibles communes et `.docker/make/<type>.mk` |
| `.docker/project/` | fichiers montés par les deux précédents (convention) : `nginx.conf`, `php.ini`… |
| `.docker/docker-compose.override.yml` | **non versionné** (`.gitignore`), local seulement (jamais chargé en `ENV=prod`) : réglage du poste, ex. route d'exposition temporaire |

Un service ajouté rejoint les mêmes réseaux que les services communs (`project_network`, et `databases` / `mailer`
s'il en a besoin), sans base ni serveur de mail à lui. Compose fusionne les fichiers : un `build.args`, un volume ou
un label du projet s'ajoute à ceux du service commun (vérifier avec `docker compose … config`).

| Besoin | Où | Exemple |
|---|---|---|
| Image PHP : wkhtmltopdf, pcov, paquets, extensions PECL | `services.php.build.args` des deux `project.yml` (jamais `.docker/.env`, comme la version PHP) | voir ci-dessous (1) |
| PHP ini propre au projet (envois plus gros…) | volume sur `/usr/local/etc/php/conf.d/95-project.ini`, services `php` **et** `worker` | (2) |
| Règles nginx (location, `client_max_body_size`…, niveau `server`) | volume sur `/etc/nginx/project.d/project.conf` du service `nginx` | (3) |
| Remplacer une cible du modèle (`clean-cache`, `init-dev`, `deploy`…) | `PROJECT_OVERRIDES` dans `project.mk` | (4) |
| Maintenance (Symfony) | cibles du projet qui posent `var/maintenance.flag` | (5) |
| Réglage local du poste | `.docker/docker-compose.override.yml` (non versionné) | (6) |

(1) Compléments de l'image PHP, tous à `0` / vides par défaut. wkhtmltopdf : 0.12.6.1 à Qt patché,
`/usr/local/bin/wkhtmltopdf`, amd64. Les extensions PECL sont installées puis activées (`redis-6.2.0` pour une
version précise).

```yaml
# .docker/docker-compose.project.yml (et le même bloc dans docker-compose.prod.project.yml)
services:
    php:
        build:
            args:
                ENABLE_WKHTMLTOPDF: 1
                ENABLE_PCOV: 1                      # local seulement, en général
                EXTRA_APT_PACKAGES: librabbitmq-dev libmagickwand-dev ghostscript poppler-utils
                EXTRA_PECL_EXTENSIONS: amqp imagick
```

(2) PHP ini du projet, lu après `90-extra-config.ini`. Un fichier monté seul garde l'ancienne version après un
`git pull` tant que le conteneur n'est pas recréé : après une modification,
`docker compose … up -d --force-recreate --no-deps php` (et `worker`).

```ini
; .docker/project/php.ini
upload_max_filesize = 100M
post_max_size = 100M
```

```yaml
services:
    php:
        volumes:
            - ./project/php.ini:/usr/local/etc/php/conf.d/95-project.ini:ro
    worker:                                         # prod, s'il existe
        volumes:
            - ./project/php.ini:/usr/local/etc/php/conf.d/95-project.ini:ro
```

(3) Règles nginx du projet, incluses dans le bloc `server` de chaque config de type, juste après le refus des
chemins cachés et avant les autres blocs regex (une location regex du projet passe avant le bloc PHP).
`client_max_body_size` est posé au niveau `http` par le modèle : le projet peut le redéfinir ici (sauf
PrestaShop, dont la location PHP fixe sa propre limite). Un dossier peut être monté à la place du fichier
(`./project/nginx/:/etc/nginx/project.d:ro`, fichiers `*.conf`). `make ENV=prod deploy` recrée nginx, la
règle est appliquée au déploiement.

```nginx
# .docker/project/nginx.conf
client_max_body_size 100M;
location ~ ^/legacy/.*\.php$ { return 410; }
```

```yaml
services:
    nginx:
        volumes:
            - ./project/nginx.conf:/etc/nginx/project.d/project.conf:ro
```

(4) Remplacer une cible du modèle : `project.mk` est lu avant les cibles communes et le fichier du type ; chaque
cible du modèle n'est définie que si elle n'est pas listée dans `PROJECT_OVERRIDES` (pas d'alerte « overriding
recipe », `make help` n'affiche que celle du projet). Une cible non listée reste celle du modèle.

```make
# .docker/make/project.mk
PROJECT_OVERRIDES := clean-cache init-dev

clean-cache: ## vide le cache et le pool Redis
	$(CONSOLE) cache:clear --env=$(ENV)
	$(CONSOLE) cache:pool:clear cache.app --env=$(ENV)
```

`$(CONSOLE)`, `$(EXEC_NODEJS)` sont définis par le fichier du type, lu après : utilisables dans les recettes (lues
à l'exécution), pas dans une affectation `:=` de `project.mk`. `$(DOCKER_COMPOSE)`, `$(EXEC_PHP)`,
`$(RECREATE_NGINX)` le sont avant.

(5) Maintenance Symfony :

```make
maintenance-on: ## site en maintenance (503)
	$(EXEC_PHP) touch var/maintenance.flag
maintenance-off: ## fin de maintenance
	$(EXEC_PHP) rm -f var/maintenance.flag
```

(6) Local, non versionné : ajouté après les autres fichiers quand `ENV` n'est pas `prod`.

```yaml
# .docker/docker-compose.override.yml
services:
    nginx:
        labels:
            - "traefik.http.routers.site-demo.rule=Host(`demo.example.com`)"
            - "traefik.http.routers.site-demo.entrypoints=websecure"
            - "traefik.http.routers.site-demo.tls=true"
```
