#!/usr/bin/env bats
# bin/infra-check — tout est fichier : aucun docker (INFRA_SKIP_DOCKER=1).

setup() {
  export ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SANDBOX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/infra.XXXXXX")"
  export INFRA_ROOT="$SANDBOX/infra"
  export INFRA_ENV_FILE="$INFRA_ROOT/.env"
  export INFRA_SKIP_DOCKER=1
  mkdir -p "$INFRA_ROOT/configuration/traefik2/config/dynamic/local" \
           "$INFRA_ROOT/configuration/traefik2/config/dynamic/prod" \
           "$INFRA_ROOT/configuration/traefik2/certs"
  cp "$ROOT/configuration/traefik2/config/traefik.local.yaml" "$ROOT/configuration/traefik2/config/traefik.prod.yaml" "$INFRA_ROOT/configuration/traefik2/config/"
  cp "$ROOT/configuration/traefik2/config/dynamic/local/main.yaml" "$INFRA_ROOT/configuration/traefik2/config/dynamic/local/"
  cp "$ROOT/configuration/traefik2/config/dynamic/prod/main.yaml" "$INFRA_ROOT/configuration/traefik2/config/dynamic/prod/"
  touch "$INFRA_ROOT/configuration/traefik2/certs/docker.localhost.pem" "$INFRA_ROOT/configuration/traefik2/certs/docker.localhost-key.pem"
  # Dossier de config gatus fourni par l'hôte : HORS du checkout, rempli avec l'exemple versionné.
  export GATUS_DIR="$SANDBOX/gatus-config"
  mkdir -p "$GATUS_DIR"
  cp "$ROOT/configuration/gatus/example/config.yaml" "$GATUS_DIR/"
  unset PROFILES COMPOSE_PROFILES
  PATH="$ROOT/bin:$PATH"
}
teardown() { rm -rf "$SANDBOX"; }

env_local() {
  cat > "$INFRA_ENV_FILE" <<'EOF'
ENV=local
TRAEFIK_DASHBOARD_INSECURE=true
TRAEFIK_MONITORING_MIDDLEWARE=
TRAEFIK_DASHBOARD_USERS=admin:{SHA}abc=
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERTRESOLVER=
TRAEFIK_BIND=127.0.0.1:
LETSENCRYPT_EMAIL=you@example.com
MYSQL_ROOT_PASSWORD=s3cret
TRAEFIK_MAILPIT_MIDDLEWARE=
TRAEFIK_MAILPIT_USERS=
TRAEFIK_PHPMYADMIN_USERS=admin:$$2y$$05$$abcdef
MONITORING_DOMAIN=monitoring.docker.test
PMA_DOMAIN=phpmyadmin.docker.test
MAILPIT_DOMAIN=mailer.docker.test
EOF
}
env_prod() {
  cat > "$INFRA_ENV_FILE" <<'EOF'
ENV=prod
TRAEFIK_DASHBOARD_INSECURE=false
TRAEFIK_MONITORING_MIDDLEWARE=auth
TRAEFIK_DASHBOARD_USERS=admin:{SHA}abc=
TRAEFIK_ENTRYPOINT=websecure
TRAEFIK_CERTRESOLVER=le
TRAEFIK_BIND=
LETSENCRYPT_EMAIL=ops@example.org
MYSQL_ROOT_PASSWORD=s3cret
TRAEFIK_MAILPIT_MIDDLEWARE=mailpit-auth
TRAEFIK_MAILPIT_USERS=admin:{SHA}abc=
TRAEFIK_PHPMYADMIN_USERS=admin:$$2y$$05$$abcdef
MONITORING_DOMAIN=monitoring.example.org
PMA_DOMAIN=pma.example.org
MAILPIT_DOMAIN=mail.example.org
EOF
}

# Active le profil gatus avec toutes ses variables.
gatus_on() {
  cat >> "$INFRA_ENV_FILE" <<EOF
COMPOSE_PROFILES=mariadb,gatus
GATUS_CONFIG_DIR=$GATUS_DIR
GATUS_DOMAIN=status.docker.test
TRAEFIK_GATUS_USERS=admin:\$\$2y\$\$05\$\$abcdef
GATUS_TELEGRAM_TOKEN=123:abc
GATUS_TELEGRAM_CHAT_ID=42
EOF
}
set_var() { sed -i "s|^$1=.*|$1=$2|" "$INFRA_ENV_FILE"; }

@test "sans .env : échec explicite" {
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *".env absent"* ]]
}

@test "local complet : OK" {
  env_local
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra-check : OK (local)"* ]]
}

@test "prod complet : OK" {
  env_prod
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (prod)"* ]]
}

@test "ENV inconnu : échec" {
  env_local; sed -i 's/^ENV=local/ENV=staging/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"ENV doit valoir"* ]]
}

@test "TRAEFIK_PHPMYADMIN_USERS vide : échec (phpMyAdmin tomberait en 404)" {
  env_local; sed -i 's/^TRAEFIK_PHPMYADMIN_USERS=.*/TRAEFIK_PHPMYADMIN_USERS=/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRAEFIK_PHPMYADMIN_USERS vide"* ]]
}

@test "hash bcrypt avec \$ non doublé : échec" {
  env_local; sed -i 's/^TRAEFIK_PHPMYADMIN_USERS=.*/TRAEFIK_PHPMYADMIN_USERS=admin:$2y$05$abcdef/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"non doublé"* ]]
}

@test "hash {SHA} sans \$ : accepté" {
  env_local; sed -i 's/^TRAEFIK_PHPMYADMIN_USERS=.*/TRAEFIK_PHPMYADMIN_USERS=admin:{SHA}0DPiKuNIrrVmD8IUCuw1hQxNqZc=/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 0 ]
}


@test "prod : LETSENCRYPT_EMAIL d'exemple ou dashboard insecure : échec, les deux listés" {
  env_prod; sed -i 's/^LETSENCRYPT_EMAIL=.*/LETSENCRYPT_EMAIL=you@example.com/; s/^TRAEFIK_DASHBOARD_INSECURE=.*/TRAEFIK_DASHBOARD_INSECURE=true/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"LETSENCRYPT_EMAIL est la valeur d'exemple"* ]]
  [[ "$output" == *"INSECURE doit être false"* ]]
  [[ "$output" == *"2 échec"* ]]
}

@test "prod : variables d'auth obligatoires ; en local elles peuvent rester vides" {
  env_prod; sed -i 's/^TRAEFIK_MAILPIT_USERS=.*/TRAEFIK_MAILPIT_USERS=/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRAEFIK_MAILPIT_USERS vide"* ]]
  env_local
  run infra-check
  [ "$status" -eq 0 ]
}

@test "dossier dynamic/<ENV> absent : échec nommant le dossier" {
  env_prod; rm -r "$INFRA_ROOT/configuration/traefik2/config/dynamic/prod"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"dynamic/prod/ absent"* ]]
}

@test "dossier dynamic/<ENV> vide : échec" {
  env_local; rm "$INFRA_ROOT/configuration/traefik2/config/dynamic/local/main.yaml"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"dynamic/local/ est vide"* ]]
}

@test "traefik.<ENV>.yaml absent : échec" {
  env_local; rm "$INFRA_ROOT/configuration/traefik2/config/traefik.local.yaml"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"traefik.local.yaml absent"* ]]
}

@test "local sans certificat mkcert : échec renvoyant vers make certs" {
  env_local; rm "$INFRA_ROOT/configuration/traefik2/certs/docker.localhost.pem"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"make certs"* ]]
}

@test "prod avec TRAEFIK_BIND restreint : simple information, pas d'échec" {
  env_prod; sed -i 's/^TRAEFIK_BIND=.*/TRAEFIK_BIND=127.0.0.1:/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"écoute restreinte"* ]]
}

@test "les échecs sont tous listés, pas seulement le premier" {
  env_local; sed -i 's/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=/; s/^PMA_DOMAIN=.*/PMA_DOMAIN=/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"MYSQL_ROOT_PASSWORD vide"* ]]
  [[ "$output" == *"PMA_DOMAIN vide"* ]]
}

@test "mot de passe root d'exemple : échec en prod" {
  env_prod; sed -i 's/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=changeme/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"valeur d'exemple"* ]]
}

@test "mot de passe root d'exemple : toléré et signalé en local" {
  env_local; sed -i 's/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=root/' "$INFRA_ENV_FILE"
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"toléré en local"* ]]
}

@test "gatus : profil inactif, variables gatus non exigées" {
  env_local
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"profil gatus inactif"* ]]
}

@test "gatus : profil actif via COMPOSE_PROFILES du .env, complet : OK" {
  env_local; gatus_on
  run infra-check
  [ "$status" -eq 0 ]
  [[ "$output" == *"présent, hors du dépôt"* ]]
  [[ "$output" == *"variables référencées toutes transmises"* ]]
}

@test "gatus : profil actif via PROFILES (make up PROFILES=gatus)" {
  env_local
  PROFILES=gatus run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"GATUS_CONFIG_DIR vide"* ]]
}

@test "gatus : profil actif via COMPOSE_PROFILES de l'environnement" {
  env_local
  COMPOSE_PROFILES=gatus run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"GATUS_CONFIG_DIR vide"* ]]
}

@test "gatus : TRAEFIK_GATUS_USERS vide : échec (page d'état en 404)" {
  env_local; gatus_on; set_var TRAEFIK_GATUS_USERS ""
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRAEFIK_GATUS_USERS vide"* ]]
}

@test "gatus : jeton Telegram vide : échec (Gatus n'alerterait jamais, sans erreur)" {
  env_local; gatus_on; set_var GATUS_TELEGRAM_TOKEN ""; set_var GATUS_TELEGRAM_CHAT_ID ""
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"GATUS_TELEGRAM_TOKEN vide"* ]]
  [[ "$output" == *"GATUS_TELEGRAM_CHAT_ID vide"* ]]
}

@test "gatus : hash avec \$ non doublé : échec" {
  env_local; gatus_on; set_var TRAEFIK_GATUS_USERS 'admin:$2y$05$abcdef'
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"TRAEFIK_GATUS_USERS contient un"* ]]
}

@test "gatus : GATUS_CONFIG_DIR relatif : échec" {
  env_local; gatus_on; set_var GATUS_CONFIG_DIR "configuration/gatus/example"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"chemin absolu attendu"* ]]
}

@test "gatus : GATUS_CONFIG_DIR absent : échec nommant le dossier" {
  env_local; gatus_on; set_var GATUS_CONFIG_DIR "$SANDBOX/nulle-part"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"dossier $SANDBOX/nulle-part absent"* ]]
}

@test "gatus : GATUS_CONFIG_DIR dans le checkout (exemple versionné) : échec" {
  env_local; gatus_on
  mkdir -p "$INFRA_ROOT/configuration/gatus/example"
  cp "$GATUS_DIR/config.yaml" "$INFRA_ROOT/configuration/gatus/example/"
  set_var GATUS_CONFIG_DIR "$INFRA_ROOT/configuration/gatus/example"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"est dans le checkout"* ]]
}

@test "gatus : GATUS_CONFIG_DIR = lien symbolique vers le checkout : échec" {
  env_local; gatus_on
  ln -s "$INFRA_ROOT" "$SANDBOX/lien"
  set_var GATUS_CONFIG_DIR "$SANDBOX/lien"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"est dans le checkout"* ]]
}

@test "gatus : dossier sans .yaml : échec" {
  env_local; gatus_on; mkdir -p "$SANDBOX/vide"; set_var GATUS_CONFIG_DIR "$SANDBOX/vide"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"ne contient aucun .yaml"* ]]
}

@test "gatus : config référençant une variable non transmise au conteneur : échec" {
  env_local; gatus_on
  printf 'endpoints:\n  - name: x\n    url: "https://${SITE_DOMAIN}"\n    headers:\n      Authorization: "$API_TOKEN"\n    body: "$$literal"\n' \
    > "$GATUS_DIR/extra.yaml"
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"non transmise(s) au conteneur : API_TOKEN SITE_DOMAIN"* ]]
  [[ "$output" != *"literal"* ]]
}

@test "gatus : GATUS_DOMAIN identique à MONITORING_DOMAIN : échec" {
  env_local; gatus_on; set_var GATUS_DOMAIN monitoring.docker.test
  run infra-check
  [ "$status" -eq 1 ]
  [[ "$output" == *"GATUS_DOMAIN = MONITORING_DOMAIN"* ]]
}

@test "gatus : l'exemple versionné passe les contrôles fichier en prod" {
  env_prod; gatus_on
  run infra-check
  [ "$status" -eq 0 ]
}
