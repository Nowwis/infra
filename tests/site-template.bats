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
  run config docker-compose.yml
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

@test "un seul Dockerfile PHP, version en argument" {
  [ -f "$T/.docker/php/Dockerfile" ]
  grep -q '^ARG PHP_VERSION' "$T/.docker/php/Dockerfile"
  grep -q 'FROM php:${PHP_VERSION}-fpm' "$T/.docker/php/Dockerfile"
}

@test "pas de fichiers d'IDE ni de .env dans le modèle" {
  [ ! -e "$T/.idea" ]
  [ ! -e "$T/.docker/.env" ]
}
