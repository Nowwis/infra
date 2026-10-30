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

NGINX_IMAGE=site-template-nginx-test

# need_docker : ignore le test proprement si Docker n'est pas joignable
need_docker() { docker info >/dev/null 2>&1 || skip "Docker absent"; }

# nginx_image : image nginx du modèle (Dockerfile, point d'extension project.d), construite une fois
nginx_image() {
  need_docker
  docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1 && [ "${NGINX_IMAGE_BUILT:-}" = 1 ] && return
  docker build -q -t "$NGINX_IMAGE" "$T/.docker/nginx" >/dev/null
  export NGINX_IMAGE_BUILT=1
}

# stack <type> <dossier du site> [dossier project.d] : nginx du modèle + php-fpm dans le même espace réseau
# (« php » = 127.0.0.1, aucun réseau Docker créé). Sans php (STACK_NO_PHP=1), une requête PHP répond 502.
stack() {
  nginx_image
  STACK="site-tpl-$BATS_TEST_NUMBER-$$"
  chmod -R a+rwX "$2"
  local net=()
  if [ -z "${STACK_NO_PHP:-}" ]; then
    docker run -d --rm --name "$STACK-php" --add-host php:127.0.0.1 -v "$2:/var/www" php:8.4-fpm >/dev/null
    net=(--network "container:$STACK-php")
  else
    net=(--add-host php:127.0.0.1)
  fi
  docker run -d --rm --name "$STACK-nginx" "${net[@]}" \
    -v "$2:/var/www:ro" -v "$T/.docker/nginx/$1.conf:/etc/templates/nginx.conf:ro" \
    ${3:+-v "$3:/etc/nginx/project.d:ro"} "$NGINX_IMAGE" >/dev/null
  for _ in $(seq 50); do docker exec "$STACK-nginx" curl -s -o /dev/null http://127.0.0.1/ 2>/dev/null && return; sleep 0.1; done
  docker logs "$STACK-nginx"; return 1
}

# get <chemin>… : « chemin statut corps(40 premiers octets) » par ligne, depuis le conteneur nginx
get() {
  local p
  for p in "$@"; do
    docker exec "$STACK-nginx" sh -c "c=\$(curl -s -o /tmp/b -w '%{http_code}' 'http://127.0.0.1$p'); printf '%s %s %s\n' '$p' \"\$c\" \"\$(head -c 40 /tmp/b | tr -d '\r\n')\""
  done
}

teardown() {
  if [ -n "${STACK:-}" ]; then
    docker rm -f "$STACK-nginx" "$STACK-php" >/dev/null 2>&1 || true
  fi
}

# nodejs_command : commande du service nodejs (local) sur une ligne, sans repli YAML
nodejs_command() {
  (cd "$S/.docker" && docker compose -f docker-compose.yml config --format json) | jq -r '.services.nodejs.command | join(" ")'
}

@test "chaque type se rend en local avec ses seuls services" {
  use_type html;       [ "$(services docker-compose.yml)" = "nginx" ]
  use_type wordpress;  [ "$(services docker-compose.yml)" = "nginx php" ]
  use_type prestashop; [ "$(services docker-compose.yml)" = "nginx php" ]
  use_type symfony;    [ "$(services docker-compose.yml)" = "nginx nodejs php" ]
  use_type php;        [ "$(services docker-compose.yml)" = "nginx php" ]
}

@test "chaque type a sa config nginx et sa cible make" {
  for t in html symfony wordpress prestashop php; do
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

@test "symfony : make deploy = cible minimale, ou le post_deploy commun .docker/make/deploy.mk s'il est présent" {
  use_type symfony
  run make -C "$S" -n deploy ENV=prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"composer install"* ]]
  printf 'deploy: deploy-common\ndeploy-common:\n\t@echo POST-DEPLOY-COMMUN\n' > "$S/.docker/make/deploy.mk"
  run make -C "$S" deploy ENV=prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"POST-DEPLOY-COMMUN"* ]]
  [[ "$output" != *"composer install"* ]]
  run make -C "$S" help
  [ "$(grep -c 'deploy ' <<<"$output")" -eq 1 ]
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
  for t in html symfony wordpress prestashop php; do
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
  for t in html symfony wordpress prestashop php; do
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

@test "fichiers propres au projet : docker-compose.project.yml (local) / .prod.project.yml (prod) et make/project.mk chargés s'ils existent" {
  d="$BATS_TEST_TMPDIR/site"; cp -r "$BATS_TEST_DIRNAME/../templates/site" "$d"; cd "$d"; cp .docker/.env.example .docker/.env
  [[ "$(make -pn 2>/dev/null | grep '^COMPOSE_FILES')" != *project* ]]
  printf 'services: {}\n' > .docker/docker-compose.project.yml
  [[ "$(make -pn 2>/dev/null | grep '^COMPOSE_FILES')" == *"-f .docker/docker-compose.project.yml"* ]]
  [[ "$(make -pn ENV=prod 2>/dev/null | grep '^COMPOSE_FILES')" != *project* ]]
  printf 'services: {}\n' > .docker/docker-compose.prod.project.yml
  [[ "$(make -pn ENV=prod 2>/dev/null | grep '^COMPOSE_FILES')" == *"-f .docker/docker-compose.prod.project.yml"* ]]
  printf 'bonjour: ## test\n\t@echo BONJOUR\n' > .docker/make/project.mk
  run make bonjour
  [ "$status" -eq 0 ]; [ "$output" = BONJOUR ]
}

@test "project.mk lu avant le type : une variable du projet est visible du fichier du type" {
  d="$BATS_TEST_TMPDIR/site"; cp -r "$BATS_TEST_DIRNAME/../templates/site" "$d"; cd "$d"; cp .docker/.env.example .docker/.env
  printf 'PROJECT_SETTING := oui\n' > .docker/make/project.mk
  printf 'ifeq ($(PROJECT_SETTING),oui)\nvu-par-le-type: ; @echo VU\nendif\n' >> ".docker/make/$(sed -n 's/^PROJECT_TYPE=//p' .docker/.env).mk"
  run make vu-par-le-type
  [ "$status" -eq 0 ]; [ "$output" = VU ]
}

@test "php : type PHP natif, profil php, racine = racine du projet" {
  grep -q '^# symfony | wordpress | prestashop | php | html$' "$T/.docker/.env.example"
  grep -q 'root /var/www;' "$T/.docker/nginx/php.conf"
  grep -q 'try_files $uri $uri/ /index.php$is_args$args;' "$T/.docker/nginx/php.conf"
  grep -q 'map $http_x_forwarded_proto $fastcgi_https' "$T/.docker/nginx/php.conf"
  grep -q '| `php` | nginx, php (`php`) | racine du projet |' "$T/README.md"
}

@test "image PHP : soap commun, compléments par args désactivés par défaut" {
  f="$T/.docker/php/Dockerfile"
  grep -Eq 'docker-php-ext-install .* soap' "$f"
  grep -q 'libxml2-dev' "$f"
  grep -qx 'ARG ENABLE_WKHTMLTOPDF=0' "$f"
  grep -qx 'ARG ENABLE_PCOV=0' "$f"
  grep -qx 'ARG EXTRA_APT_PACKAGES=""' "$f"
  grep -qx 'ARG EXTRA_PECL_EXTENSIONS=""' "$f"
  grep -q 'wkhtmltox_0.12.6.1-3.bookworm_amd64.deb' "$f"
  # Jamais dans .docker/.env (non synchronisé au déploiement), comme la version PHP.
  run grep -E 'ENABLE_WKHTMLTOPDF|ENABLE_PCOV|EXTRA_APT|EXTRA_PECL' "$T/.docker/.env.example" "$T/.docker/docker-compose.yml" "$T/.docker/docker-compose.prod.yml"
  [ "$status" -eq 1 ]
}

@test "image PHP : les args d'un project.yml se fusionnent avec ceux du fichier commun (local et prod)" {
  use_type symfony
  for f in docker-compose.project.yml docker-compose.prod.project.yml; do
    printf 'services:\n    php:\n        build:\n            args:\n                ENABLE_WKHTMLTOPDF: 1\n                EXTRA_PECL_EXTENSIONS: amqp imagick\n' > "$S/.docker/$f"
  done
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.yml -f docker-compose.project.yml config --format json | jq -c '.services.php.build.args'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ENABLE_WKHTMLTOPDF":"1"'* ]]
  [[ "$output" == *'"EXTRA_PECL_EXTENSIONS":"amqp imagick"'* ]]
  [[ "$output" == *'"COMPOSER_VERSION":"2"'* ]]
  [[ "$output" == *'"UID":"1000"'* ]]
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml -f docker-compose.prod.project.yml config --format json | jq -c '.services.php.build.args'"
  [[ "$output" == *'"ENABLE_WKHTMLTOPDF":"1"'* ]]
  [[ "$output" == *'"ENABLE_XDEBUG":"0"'* ]]
}

@test "image PHP : build réel avec wkhtmltopdf, pcov, amqp, imagick (SITE_TEMPLATE_BUILD=1, lent)" {
  [ "${SITE_TEMPLATE_BUILD:-}" = 1 ] || skip "SITE_TEMPLATE_BUILD=1 pour construire l'image complète"
  need_docker
  docker build -q -t site-template-php-test --build-arg ENABLE_WKHTMLTOPDF=1 --build-arg ENABLE_PCOV=1 \
    --build-arg EXTRA_APT_PACKAGES="librabbitmq-dev libmagickwand-dev ghostscript poppler-utils" \
    --build-arg EXTRA_PECL_EXTENSIONS="amqp imagick" "$T/.docker/php" >/dev/null
  run docker run --rm site-template-php-test sh -c 'php -m; wkhtmltopdf --version; pdftotext -v 2>&1 | head -1;
    echo "<h1>ok</h1>" > /tmp/a.html && wkhtmltopdf -q /tmp/a.html /tmp/a.pdf && head -c 5 /tmp/a.pdf'
  [ "$status" -eq 0 ]
  for m in soap amqp imagick pcov; do grep -qx "$m" <<<"$output" || { echo "$m absent"; return 1; }; done
  [[ "$output" == *"wkhtmltopdf 0.12.6.1 (with patched qt)"* ]]
  [[ "$output" == *"pdftotext version"* ]]
  [[ "$output" == *"%PDF-"* ]]
}

@test "php.ini commun : erreurs au journal, jamais dans la page, max_input_vars" {
  f="$T/.docker/php/90-extra-config.ini"
  grep -qx 'log_errors = On' "$f"
  grep -qx 'display_errors = Off' "$f"
  grep -qx 'max_input_vars = 10000' "$f"
  grep -q '95-project.ini' "$T/README.md"
}

@test "prod : le worker lit le php.ini commun comme php" {
  use_type symfony
  sed -i "s/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=php,worker/" "$S/.docker/.env"
  run bash -c "cd '$S/.docker' && docker compose -f docker-compose.prod.yml config --format json | jq -r '.services.worker.volumes[].target'"
  [[ "$output" == *"/usr/local/etc/php/conf.d/90-extra-config.ini"* ]]
}

@test "nginx : include project.d juste après le refus des chemins cachés, avant tout autre bloc regex" {
  grep -q 'mkdir -p /etc/nginx/project.d' "$T/.docker/nginx/Dockerfile"
  for t in html symfony wordpress prestashop php; do
    c="$T/.docker/nginx/$t.conf"
    run awk '/location ~ \/\\\.\(\?!well-known\/\) \{/{d=NR} /include \/etc\/nginx\/project.d\/\*\.conf;/{i=NR} /^\s+location ~/{if(!f){f=NR} else if(!s){s=NR}} END{print d, i, f, s}' "$c"
    read -r deny inc first second <<<"$output"
    [ "$deny" = "$first" ] || { echo "$t : premier regex $first, refus $deny"; return 1; }
    [ -n "$inc" ] && [ "$inc" -gt "$deny" ] && [ "$inc" -lt "$second" ] || { echo "$t : include $inc ($deny..$second)"; return 1; }
  done
}

@test "nginx : chaque config passe nginx -t dans l'image du modèle, avec et sans fichier du projet" {
  nginx_image
  pd="$BATS_TEST_TMPDIR/project.d"; mkdir -p "$pd"
  printf 'client_max_body_size 100M;\nlocation ~ ^/legacy/.*\\.php$ { return 410; }\n' > "$pd/project.conf"
  for t in html symfony wordpress prestashop php; do
    run docker run --rm --add-host php:127.0.0.1 -v "$T/.docker/nginx/$t.conf:/etc/templates/nginx.conf:ro" \
      "$NGINX_IMAGE" sh -c '/docker-entrypoint.d/99-change.sh && nginx -t'
    [ "$status" -eq 0 ] || { echo "$t sans projet : $output"; return 1; }
    run docker run --rm --add-host php:127.0.0.1 -v "$pd:/etc/nginx/project.d:ro" \
      -v "$T/.docker/nginx/$t.conf:/etc/templates/nginx.conf:ro" "$NGINX_IMAGE" sh -c '/docker-entrypoint.d/99-change.sh && nginx -t'
    [ "$status" -eq 0 ] || { echo "$t avec projet : $output"; return 1; }
  done
}

@test "nginx : une directive de niveau server du projet s'applique (client_max_body_size)" {
  for t in symfony wordpress php; do
    w="$BATS_TEST_TMPDIR/$t"; pd="$BATS_TEST_TMPDIR/$t-pd"; mkdir -p "$w/public" "$pd"
    touch "$w/index.php" "$w/public/index.php"
    STACK_NO_PHP=1 stack "$t" "$w"
    run docker exec "$STACK-nginx" sh -c 'head -c 30000000 /dev/zero > /tmp/big; curl -s -o /dev/null -w "%{http_code}" --data-binary @/tmp/big http://127.0.0.1/index.php'
    [ "$output" = 413 ] || { echo "$t sans projet : $output"; return 1; }
    teardown
    echo 'client_max_body_size 100M;' > "$pd/project.conf"
    STACK_NO_PHP=1 stack "$t" "$w" "$pd"
    run docker exec "$STACK-nginx" sh -c 'head -c 30000000 /dev/zero > /tmp/big; curl -s -o /dev/null -w "%{http_code}" --data-binary @/tmp/big http://127.0.0.1/index.php'
    [ "$output" = 502 ] || { echo "$t avec projet : $output"; return 1; }
    teardown
  done
  STACK=
}

@test "symfony : seul index.php s'exécute, une location regex du projet passe avant le bloc PHP" {
  w="$BATS_TEST_TMPDIR/sf"; pd="$BATS_TEST_TMPDIR/sf-pd"; mkdir -p "$w/public/uploads" "$w/var" "$pd"
  echo '<?php echo "FRONT ".$_SERVER["REQUEST_URI"];' > "$w/public/index.php"
  echo '<?php echo "PWNED";' > "$w/public/uploads/x.php"
  echo '<?php echo "OTHER";' > "$w/public/other.php"
  printf 'location ~ ^/legacy/.*\\.php$ { return 410; }\n' > "$pd/project.conf"
  stack symfony "$w" "$pd"
  run get / /index.php /une/route /index.php/x /uploads/x.php /other.php /legacy/a.php
  echo "$output"
  [[ "$output" == *"/ 200 FRONT /"* ]]
  [[ "$output" == *"/index.php 200 FRONT /index.php"* ]]
  [[ "$output" == *"/une/route 200 FRONT /une/route"* ]]
  [[ "$output" == *"/index.php/x 200 FRONT"* ]]
  [[ "$output" == *"/uploads/x.php 404"* ]]
  [[ "$output" == *"/other.php 404"* ]]
  [[ "$output" == *"/legacy/a.php 410"* ]]
  [[ "$output" != *"PWNED"* && "$output" != *"OTHER"* ]]
}

@test "symfony : maintenance (var/maintenance.flag) → 503 partout, maintenance.html servie, sans boucle" {
  w="$BATS_TEST_TMPDIR/sf"; mkdir -p "$w/public" "$w/var"
  echo '<?php echo "FRONT";' > "$w/public/index.php"
  echo '<h1>MAINTENANCE</h1>' > "$w/public/maintenance.html"
  stack symfony "$w"
  run get /
  [[ "$output" == "/ 200 FRONT" ]]
  touch "$w/var/maintenance.flag"
  run get / /index.php /une/route /maintenance.html
  echo "$output"
  [ "$(grep -c ' 503 <h1>MAINTENANCE</h1>' <<<"$output")" -eq 4 ]
  run docker exec "$STACK-nginx" curl -sI http://127.0.0.1/
  [[ "$output" == *"Retry-After: 300"* ]]
  mv "$w/public/maintenance.html" "$w/maintenance.html.off"
  run get /
  [[ "$output" == "/ 503 <html><head><title>503 Service"* ]]
  mv "$w/var/maintenance.flag" "$w/maintenance.flag.off"
  run get /
  [[ "$output" == "/ 200 FRONT" ]]
}

# root_files <dossier> : fichiers d'outillage à la racine d'un dépôt, qui ne doivent jamais être servis
root_files() {
  mkdir -p "$1/deploy" "$1/.docker"
  for f in composer.json composer.lock Makefile deploy/deploy.sh README.md CHANGELOG.md .docker/.env; do echo SECRET > "$1/$f"; done
}
ROOT_DENIED="/deploy/deploy.sh /Makefile /composer.json /composer.lock /README.md /CHANGELOG.md /.docker/.env"

@test "wordpress : outillage et fichiers d'installation refusés, wp-admin et thèmes servis" {
  w="$BATS_TEST_TMPDIR/wp"; root_files "$w"
  mkdir -p "$w/wp-admin/css" "$w/wp-content/themes/t" "$w/wp-content/plugins/p"
  echo '<?php echo "WP ".$_SERVER["REQUEST_URI"];' > "$w/index.php"
  echo '<?php echo "ADMIN";' > "$w/wp-admin/index.php"
  echo '<?php echo "LOGIN";' > "$w/wp-login.php"
  echo 'a{}' > "$w/wp-admin/css/x.css"; echo 'b{}' > "$w/wp-content/themes/t/style.css"
  echo 'doc' > "$w/wp-content/plugins/p/readme.md"
  for f in readme.html license.txt wp-config-sample.php; do echo SECRET > "$w/$f"; done
  stack wordpress "$w"
  run get / /un-article/ /wp-admin/ /wp-login.php /wp-admin/css/x.css /wp-content/themes/t/style.css \
    /wp-content/plugins/p/readme.md $ROOT_DENIED /readme.html /license.txt /wp-config-sample.php
  echo "$output"
  [[ "$output" == *"/ 200 WP /"* ]]
  [[ "$output" == *"/un-article/ 200 WP /un-article/"* ]]
  [[ "$output" == *"/wp-admin/ 200 ADMIN"* ]]
  [[ "$output" == *"/wp-login.php 200 LOGIN"* ]]
  [[ "$output" == *"/wp-admin/css/x.css 200 a{}"* ]]
  [[ "$output" == *"/wp-content/themes/t/style.css 200 b{}"* ]]
  [[ "$output" == *"/wp-content/plugins/p/readme.md 200 doc"* ]]
  for p in $ROOT_DENIED /readme.html /license.txt /wp-config-sample.php; do
    [[ "$output" == *"$p 403"* ]] || { echo "$p non refusé"; return 1; }
  done
  [[ "$output" != *SECRET* ]]
}

@test "prestashop : outillage à la racine refusé, front et thème servis" {
  w="$BATS_TEST_TMPDIR/ps"; root_files "$w"; mkdir -p "$w/themes/t"
  echo '<?php echo "PS ".$_SERVER["REQUEST_URI"];' > "$w/index.php"
  echo 't{}' > "$w/themes/t/a.css"; echo SECRET > "$w/Makefile.prestashop"
  stack prestashop "$w"
  run get / /fr/un-produit /themes/t/a.css $ROOT_DENIED /Makefile.prestashop
  echo "$output"
  [[ "$output" == *"/ 200 PS /"* ]]
  [[ "$output" == *"/fr/un-produit 200 PS /fr/un-produit"* ]]
  [[ "$output" == *"/themes/t/a.css 200 t{}"* ]]
  for p in $ROOT_DENIED /Makefile.prestashop; do
    [[ "$output" == *"$p 403"* ]] || { echo "$p non refusé"; return 1; }
  done
}

@test "php : scripts et routes servis, outillage, vendor/ et .php envoyés refusés, HTTPS transmis" {
  w="$BATS_TEST_TMPDIR/php"; root_files "$w"; mkdir -p "$w/vendor" "$w/uploads" "$w/css"
  echo '<?php echo "APP ".$_SERVER["REQUEST_URI"];' > "$w/index.php"
  echo '<?php echo "CONTACT";' > "$w/contact.php"
  echo '<?php echo "HTTPS=".($_SERVER["HTTPS"] ?? "");' > "$w/https.php"
  echo 'c{}' > "$w/css/s.css"; echo SECRET > "$w/vendor/autoload.php"; echo '<?php echo "PWNED";' > "$w/uploads/x.php"
  stack php "$w"
  run get / /une/route /contact.php /css/s.css /absent.php /vendor/autoload.php /uploads/x.php $ROOT_DENIED
  echo "$output"
  [[ "$output" == *"/ 200 APP /"* ]]
  [[ "$output" == *"/une/route 200 APP /une/route"* ]]
  [[ "$output" == *"/contact.php 200 CONTACT"* ]]
  [[ "$output" == *"/css/s.css 200 c{}"* ]]
  [[ "$output" == *"/absent.php 404"* ]]
  for p in /vendor/autoload.php /uploads/x.php $ROOT_DENIED; do
    [[ "$output" == *"$p 403"* ]] || { echo "$p non refusé"; return 1; }
  done
  run docker exec "$STACK-nginx" curl -s -H 'X-Forwarded-Proto: https' http://127.0.0.1/https.php
  [ "$output" = "HTTPS=on" ]
}

@test "deploy des types non Symfony : nginx recréé après up --build (config régénérée)" {
  for t in html wordpress prestashop php; do
    use_type "$t"
    run make -C "$S" -n ENV=prod deploy
    [ "$status" -eq 0 ] || { echo "$t : $output"; return 1; }
    build="$(grep -n 'up -d --remove-orphans --build' <<<"$output" | head -1 | cut -d: -f1)"
    recreate="$(grep -n 'up -d --force-recreate --no-deps nginx' <<<"$output" | tail -1 | cut -d: -f1)"
    [ -n "$build" ] && [ -n "$recreate" ] && [ "$recreate" -gt "$build" ] || { echo "$t : $output"; return 1; }
    [[ "$output" == *"-f .docker/docker-compose.prod.yml up -d --force-recreate"* ]]
  done
}

@test "PROJECT_OVERRIDES : une cible listée et redéfinie dans project.mk remplace celle du modèle, sans alerte" {
  use_type symfony
  printf 'PROJECT_OVERRIDES := clean-cache init-dev up\nclean-cache: ## cache du projet\n\t@echo PROJET-CLEAN\ninit-dev:\n\t@echo PROJET-INIT\nup:\n\t@echo PROJET-UP\n' > "$S/.docker/make/project.mk"
  run make -C "$S" --no-print-directory clean-cache init-dev up
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'PROJET-CLEAN\nPROJET-INIT\nPROJET-UP')" ]
  # Non listée : recette du modèle.
  run make -C "$S" -n migrate
  [[ "$output" == *"doctrine:migrations:migrate"* ]]
  # deploy (du modèle) appelle la cible remplacée.
  run make -C "$S" -n ENV=prod deploy
  [[ "$output" == *"echo PROJET-CLEAN"* ]]
  [[ "$output" != *"cache:clear"* ]]
  run make -C "$S" help
  [ "$(grep -c 'clean-cache' <<<"$output")" -eq 1 ]
  [[ "$output" == *"cache du projet"* ]]
  for t in wordpress prestashop html php; do
    use_type "$t"
    printf 'PROJECT_OVERRIDES := deploy\ndeploy:\n\t@echo PROJET-DEPLOY\n' > "$S/.docker/make/project.mk"
    run make -C "$S" --no-print-directory ENV=prod deploy
    [ "$output" = PROJET-DEPLOY ] || { echo "$t : $output"; return 1; }
  done
}

@test "PROJECT_OVERRIDES : une cible redéfinie sans être listée reste celle du modèle (make alerte)" {
  use_type prestashop
  printf 'clean-cache:\n\t@echo PROJET\n' > "$S/.docker/make/project.mk"
  run make -C "$S" -n clean-cache
  [[ "$output" == *"overriding recipe"* ]]
  [[ "$output" == *"var/cache/dev var/cache/prod"* ]]
}

@test "prestashop : clean-cache vide var/cache/dev et var/cache/prod (PrestaShop suit _PS_MODE_DEV_, pas ENV)" {
  use_type prestashop
  for env in dev prod; do
    for d in dev prod; do
      mkdir -p "$S/var/cache/$d/smarty"; touch "$S/var/cache/$d/smarty/x.php" "$S/var/cache/$d/class_index.php" \
        "$S/var/cache/$d/.gitkeep" "$S/var/cache/$d/index.php"
    done
    touch "$S/var/cache/.gitkeep"
    run make -C "$S" --no-print-directory clean-cache ENV="$env" EXEC_PHP=
    [ "$status" -eq 0 ] || { echo "$env : $output"; return 1; }
    for d in dev prod; do
      [ -d "$S/var/cache/$d" ] && [ -f "$S/var/cache/$d/.gitkeep" ] && [ -f "$S/var/cache/$d/index.php" ]
      [ ! -e "$S/var/cache/$d/smarty" ] && [ ! -e "$S/var/cache/$d/class_index.php" ] || { echo "$env : var/cache/$d non vidé"; return 1; }
    done
    [ -f "$S/var/cache/.gitkeep" ]
  done
  # Dossiers absents : pas d'échec.
  rm -r "$S/var"
  run make -C "$S" --no-print-directory clean-cache EXEC_PHP=
  [ "$status" -eq 0 ]
}

@test "symfony : init-dev passe --env à chaque commande console (ENV=test ne touche pas la base dev)" {
  use_type symfony
  run make -C "$S" -n init-dev ENV=test
  [ "$status" -eq 0 ]
  [ "$(grep -c 'bin/console' <<<"$output")" -eq 4 ]
  [ "$(grep -c 'bin/console .*--env=test' <<<"$output")" -eq 4 ]
}

@test "docker-compose.override.yml : chargé en local seulement, ignoré par git" {
  use_type html
  run make -C "$S" -pn
  [[ "$(grep '^COMPOSE_FILES' <<<"$output")" != *override* ]]
  printf 'services: {}\n' > "$S/.docker/docker-compose.override.yml"
  printf 'services: {}\n' > "$S/.docker/docker-compose.project.yml"
  run make -C "$S" -n up
  [[ "$output" == *"-f .docker/docker-compose.project.yml -f .docker/docker-compose.override.yml up"* ]]
  run make -C "$S" -n up ENV=prod
  [[ "$output" != *override* ]]
  grep -qx '/.docker/docker-compose.override.yml' "$T/.gitignore"
}
