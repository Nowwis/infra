#!/usr/bin/env bats
# Modèle de site (templates/site) : rendu Compose par type, local et prod, sans démarrer de conteneur.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$ROOT/templates/site"
  S="$BATS_TEST_TMPDIR/site"
  cp -r "$T" "$S"
  cp "$S/.docker/.env.example" "$S/.docker/.env"
}

# use_type <type> : PROJECT_TYPE et profils comme les pose `project new`
use_type() {
  local profiles
  case "$1" in
    html) profiles="" ;;
    symfony) profiles="php,assets" ;;
    *) profiles="php" ;;
  esac
  sed -i -e "s/^PROJECT_TYPE=.*/PROJECT_TYPE=$1/" -e "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=$profiles/" "$S/.docker/.env"
}

# services <fichier compose> : services actifs, triés, sur une ligne
services() {
  (cd "$S/.docker" && docker compose -f "$1" config --services) | sort | tr '\n' ' ' | sed 's/ $//'
}

config() { (cd "$S/.docker" && docker compose -f "$1" config); }

# nodejs_command : commande du service nodejs (local) sur une ligne, sans repli YAML
nodejs_command() {
  (cd "$S/.docker" && docker compose -f docker-compose.yml config --format json) | jq -r '.services.nodejs.command | join(" ")'
}

@test "chaque type se rend en local avec ses seuls services" {
  use_type html;       [ "$(services docker-compose.yml)" = "nginx" ]
  use_type wordpress;  [ "$(services docker-compose.yml)" = "nginx php" ]
  use_type prestashop; [ "$(services docker-compose.yml)" = "nginx php" ]
  use_type symfony;    [ "$(services docker-compose.yml)" = "nginx nodejs php" ]
}

@test "chaque type a sa config nginx et sa cible make" {
  for t in html symfony wordpress prestashop; do
    [ -f "$T/.docker/nginx/$t.conf" ]
    [ -f "$T/.docker/make/$t.mk" ]
  done
}

@test "local : domaine .docker.test, TLS sans resolver, sans middleware de prod" {
  use_type wordpress
  run config docker-compose.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *'Host(`site.docker.test`)'* ]]
  [[ "$output" == *"traefik.http.routers.site.tls: \"true\""* ]]
  [[ "$output" != *"security-headers"* ]]
  [[ "$output" == *"traefik.docker.network: traefik"* ]]
  [[ "$output" != *"docker.localhost"* ]]
}

@test "nodejs ne fait pas tourner de watch : installe puis reste inactif" {
  use_type symfony
  run nodejs_command
  [[ "$output" != *"--watch"* ]]
  [[ "$output" == *"yarn install"* ]]
  [[ "$output" == *"tail -f /dev/null"* ]]
}

@test "prod : resolver le, domaine de prod, pas d'alias www par défaut" {
  use_type wordpress
  run config docker-compose.prod.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *'Host(`site.example`)'* ]]
  [[ "$output" == *"certresolver: le"* ]]
  [[ "$output" == *"security-headers@file"* ]]
  [[ "$output" != *"www."* ]]
}

@test "prod : alias www seulement avec le fichier dédié (domaine racine)" {
  use_type wordpress
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml -f docker-compose.prod.www.yml config"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Host(`www.site.example`)'* ]]
  [[ "$output" == *"redirectregex"* ]]
}

@test "prod : sans TRAEFIK_AUTH_USERS, aucun middleware d'authentification attaché" {
  use_type wordpress
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml config --format json | jq -r '.services.nginx.labels[\"traefik.http.routers.site.middlewares\"]'"
  [ "$status" -eq 0 ]
  [ "$output" = "security-headers@file" ]
}

@test "dev sur le serveur : domaine dev, nom distinct, basic auth attachée, hash intact" {
  use_type wordpress
  sed -i -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=site-dev/' \
    -e 's/^COMPOSE_PRODUCTION_DOMAIN=.*/COMPOSE_PRODUCTION_DOMAIN=dev.site.example/' "$S/.docker/.env"
  printf '%s\n' 'TRAEFIK_AUTH_USERS=qa:$$2y$$05$$abc/def' >> "$S/.docker/.env"
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml config --format json | jq -r '.services.nginx.labels | to_entries[] | \"\\(.key)=\\(.value)\"'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'traefik.http.routers.site-dev.rule=Host(`dev.site.example`)'* ]]
  [[ "$output" == *"traefik.http.routers.site-dev.middlewares=security-headers@file,site-dev-auth"* ]]
  # `compose config` réécrit chaque $ du résultat en $$ : $$ ici = un $ simple dans le label réel.
  # Un $ non doublé dans .env aurait été lu comme une variable et le hash tronqué.
  [[ "$output" == *'traefik.http.middlewares.site-dev-auth.basicauth.users=qa:$$2y$$05$$abc/def'* ]]
}

@test "alias : TRAEFIK_ALIAS_RULE remplace www et redirige tout hôte de la règle vers le domaine" {
  use_type html
  printf '%s\n' 'TRAEFIK_ALIAS_RULE=Host(`www.site.example`) || Host(`site.example.org`)' >> "$S/.docker/.env"
  run make -C "$S" -n up ENV=prod
  [[ "$output" == *"docker-compose.prod.www.yml"* ]]
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml -f docker-compose.prod.www.yml config"
  [ "$status" -eq 0 ]
  [[ "$output" == *'rule: Host(`www.site.example`) || Host(`site.example.org`)'* ]]
  [[ "$output" == *'replacement: https://site.example$${1}'* ]]
}

@test "le modèle ne porte aucun déploiement (ajouté par l'outil de l'hôte)" {
  [ ! -e "$T/.github/workflows/deploy.yml" ]
  [ ! -e "$T/deploy" ]
}

@test "prod : le worker Symfony n'existe que sous son profil" {
  use_type symfony
  [ "$(services docker-compose.prod.yml)" = "nginx php" ]
  sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=php,worker/" "$S/.docker/.env"
  [ "$(services docker-compose.prod.yml)" = "nginx php worker" ]
}

@test "make lit le type et charge ses cibles" {
  use_type wordpress
  run make -C "$S" -n help
  [ "$status" -eq 0 ]
  run make -C "$S" -n deploy ENV=prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-compose.prod.yml"* ]]
}

@test "make prod ajoute l'alias www quand PROD_WWW_ALIAS=1" {
  use_type html
  sed -i "s/^PROD_WWW_ALIAS=.*/PROD_WWW_ALIAS=1/" "$S/.docker/.env"
  run make -C "$S" -n up ENV=prod
  [[ "$output" == *"docker-compose.prod.www.yml"* ]]
  sed -i "s/^PROD_WWW_ALIAS=.*/PROD_WWW_ALIAS=0/" "$S/.docker/.env"
  run make -C "$S" -n up ENV=prod
  [[ "$output" != *"docker-compose.prod.www.yml"* ]]
}

@test "chaque config nginx passe nginx -t" {
  for t in html symfony wordpress prestashop; do
    run docker run --rm --add-host php:127.0.0.1 -v "$T/.docker/nginx/$t.conf:/etc/nginx/nginx.conf:ro" \
      nginx:alpine nginx -t
    [ "$status" -eq 0 ] || { echo "$t : $output"; return 1; }
  done
}

@test "php.ini : limite mémoire raisonnable" {
  run grep -E '^memory_limit' "$T/.docker/php/90-extra-config.ini"
  [[ "$output" =~ memory_limit\ =\ [0-9]+M$ ]]
}

@test "un seul Dockerfile PHP, version figée dans le FROM" {
  [ -f "$T/.docker/php/Dockerfile" ]
  grep -Eq '^FROM php:[0-9]+\.[0-9]+-fpm$' "$T/.docker/php/Dockerfile"
}

@test "la version PHP n'est jamais une variable d'environnement (.env non synchronisé au déploiement)" {
  run grep -rn 'PHP_VERSION' "$T/.docker" "$T/Makefile"
  [ "$status" -eq 1 ]
}

@test "pas de fichiers d'IDE ni de .env dans le modèle" {
  [ ! -e "$T/.idea" ]
  [ ! -e "$T/.docker/.env" ]
}

@test "wordpress : sitemap et robots.txt virtuels retombent sur index.php" {
  c="$T/.docker/nginx/wordpress.conf"
  run awk '/location ~ \\.\(html\|htm\|rtf/{f=1} f&&/try_files/{print; exit} f&&/}/{exit}' "$c"
  [[ "$output" == *'try_files $uri /index.php?$args;'* ]]
  run awk '/location = \/robots.txt/{f=1} f&&/try_files/{print; exit} f&&/}/{exit}' "$c"
  [[ "$output" == *'/index.php?$args'* ]]
}

@test "image PHP : msmtp et wp-cli installés" {
  grep -Eq '^\s+git unzip curl msmtp' "$T/.docker/php/Dockerfile"
  grep -q 'wp-cli.phar' "$T/.docker/php/Dockerfile"
}

@test "mails vers Mailpit en local seulement, jamais en prod" {
  grep -q 'sendmail_path = "/usr/bin/msmtp .*--host=infra_mailer --port=1025' "$T/.docker/php/91-local-mail.ini"
  run grep -c sendmail_path "$T/.docker/php/90-extra-config.ini"
  [ "$output" = "0" ]
  use_type wordpress
  run config docker-compose.yml
  [[ "$output" == *"91-local-mail.ini"* ]]
  run config docker-compose.prod.yml
  [[ "$output" != *"91-local-mail.ini"* ]]
}

@test "wordpress : le conteneur php reçoit la base de .docker/.env" {
  use_type wordpress
  run config docker-compose.yml
  [[ "$output" == *"WORDPRESS_DB_HOST: infra_mysql_8_0"* ]]
  [[ "$output" == *"WORDPRESS_DB_NAME: site"* ]]
  [[ "$output" == *"COMPOSE_PROJECT_DOMAIN: site.docker.test"* ]]
}

@test "wp-config.local.php : syntaxe PHP valide, environnement local, réglages lus dans l'env" {
  f="$T/.docker/wp-config.local.php"
  run docker run --rm -v "$f:/w.php:ro" php:8.4-cli php -l /w.php
  [ "$status" -eq 0 ]
  grep -q "define('WP_ENVIRONMENT_TYPE', 'local')" "$f"
  grep -q "define('WP_DEBUG_LOG', true)" "$f"
  grep -q "DISABLE_WP_CRON" "$f"
  grep -q "getenv" "$f"
}

@test "wordpress : variables de copie vides par défaut, db-pull refuse sans REMOTE" {
  for v in REMOTE REMOTE_PROD PROD_URL LOCAL_URL WORDPRESS_TABLE_PREFIX; do
    grep -qx "$v=" "$T/.docker/.env.example" || { echo "$v non vide"; return 1; }
  done
  use_type wordpress
  run make -C "$S" db-pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"REMOTE et REMOTE_PROD sont requis"* ]]
  run make -C "$S" files-pull
  [ "$status" -ne 0 ]
}

@test "wordpress : db-pull remplace l'URL du serveur par l'URL locale puis purge les caches" {
  use_type wordpress
  run make -C "$S" -n db-pull REMOTE=web REMOTE_PROD=/srv/www PROD_URL=https://example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh -o BatchMode=yes web \"cd '/srv/www' && wp db export -"* ]]
  [[ "$output" == *"search-replace 'https://example.com' 'https://site.docker.test'"* ]]
  [[ "$output" == *"search-replace '//example.com' '//site.docker.test'"* ]]
  [[ "$output" == *"cache-purge"* ]]
  run make -C "$S" -n db-pull REMOTE=web REMOTE_PROD=/srv/www PROD_URL=https://example.com LOCAL_URL=https://other.docker.test
  [[ "$output" == *"'https://other.docker.test'"* ]]
}

@test "nodejs : sain seulement après l'installation de démarrage (marqueur, pas .yarn-integrity)" {
  use_type symfony
  run nodejs_command
  [[ "$output" == *"rm -f node_modules/.install-complete && if [ -f package.json ]; then yarn install; fi && mkdir -p node_modules && touch node_modules/.install-complete"* ]]
  run config docker-compose.yml
  [[ "$output" == *"/var/www/node_modules/.install-complete"* ]]
  [[ "$output" == *"retries: 60"* ]]
  [[ "$output" != *".yarn-integrity"* ]]
}

@test "chaque config nginx refuse les chemins cachés sauf /.well-known/, en premier bloc regex" {
  for t in html symfony wordpress prestashop; do
    first="$(grep -m1 -E '^\s+location ~' "$T/.docker/nginx/$t.conf")"
    [[ "$first" == *'location ~ /\.(?!well-known/) {'* ]] || { echo "$t : $first"; return 1; }
  done
}

@test "html : nginx refuse /.git/ et /.docker/, sert /.well-known/ et la page" {
  w="$BATS_TEST_TMPDIR/www"
  mkdir -p "$w/public/.git" "$w/public/.docker" "$w/public/.well-known"
  echo ok > "$w/public/index.html"; echo ref > "$w/public/.git/HEAD"
  echo secret > "$w/public/.docker/x.json"; echo acme > "$w/public/.well-known/x"
  run docker run --rm -v "$T/.docker/nginx/html.conf:/etc/nginx/nginx.conf:ro" -v "$w:/var/www:ro" \
    nginx:alpine sh -c '(nginx &) ; sleep 1; for p in / /.git/HEAD /.docker/x.json /.well-known/x; do
      printf "%s %s\n" "$p" "$(wget -S -q -O /dev/null "http://127.0.0.1$p" 2>&1 | grep -o "HTTP/1.1 [0-9]*" | head -1 | cut -d" " -f2)"; done'
  echo "$output"
  [[ "$output" == *"/ 200"* ]]
  [[ "$output" == *"/.git/HEAD 403"* ]]
  [[ "$output" == *"/.docker/x.json 403"* ]]
  [[ "$output" == *"/.well-known/x 200"* ]]
}
