# Contrat : brancher une application sur le socle

Une application **ne déclare que ses propres services** (php-fpm, nginx, workers, node…), rejoint
les réseaux externes et se publie par labels. Elle n'embarque ni base, ni reverse proxy, ni
serveur de mail.

## 1. Compose minimal

```yaml
# .docker/docker-compose.yml d'une application
services:
  php:
    build: .docker/php
    env_file: .env.local
    networks: [project_network, databases, mailer]

  nginx:
    build: .docker/nginx
    depends_on: [php]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.rule=Host(`${COMPOSE_PROJECT_DOMAIN}`)"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.entrypoints=${TRAEFIK_ENTRYPOINT}"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.tls=true"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.tls.certresolver=${TRAEFIK_CERTRESOLVER}"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}.middlewares=security-headers@file"
      - "traefik.http.services.${COMPOSE_PROJECT_NAME}.loadbalancer.server.port=80"
      - "traefik.docker.network=traefik"
    networks: [project_network, traefik]

networks:
  project_network:
  traefik:
    external: true
  databases:
    external: true
  mailer:
    external: true
```

Variables attendues dans le `.env` de l'application :

| Variable | Local | Prod |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | slug court, unique sur l'hôte | idem |
| `COMPOSE_PROJECT_DOMAIN` | `<slug>.docker.test` | vrai domaine |
| `TRAEFIK_ENTRYPOINT` | `websecure` | `websecure` |
| `TRAEFIK_CERTRESOLVER` | **vide** (mkcert via provider fichier) | `le` |
| `DATABASE_URL` | `mysql://user:pass@infra_mysql_8_0/<slug>` | `mysql://user:pass@infra_mysql_8_0/prod_<slug>` |
| `MAILER_DSN` | `smtp://infra_mailer:1025` | le vrai relais SMTP, **pas** Mailpit |

Le label `traefik.docker.network=traefik` est **obligatoire** dès qu'un service est sur
plusieurs réseaux : sans lui, Traefik peut choisir une IP du réseau privé du projet et ne jamais
joindre le conteneur (502 intermittents).

## 2. Les labels, un par un

| Label | Obligatoire | Rôle |
|---|---|---|
| `traefik.enable=true` | oui | Le socle a `exposedbydefault=false` |
| `routers.<r>.rule=Host(...)` | oui | Plusieurs hôtes : `Host(\`a\`) \|\| Host(\`b\`)` ; chemin : `&& PathPrefix(\`/api\`)` |
| `routers.<r>.entrypoints=websecure` | oui | Ne jamais publier sur `web` : il ne fait que rediriger |
| `routers.<r>.tls=true` | oui | |
| `routers.<r>.tls.certresolver=${TRAEFIK_CERTRESOLVER}` | oui | Vide en local, `le` en prod ; la variable fait le choix |
| `routers.<r>.middlewares=security-headers@file[,...]` | recommandé | En-têtes de sécurité partagés ; variante `security-headers-idp@file` pour un SSO |
| `services.<s>.loadbalancer.server.port=<port>` | oui si le conteneur expose plusieurs ports ou aucun `EXPOSE` | |
| `traefik.docker.network=traefik` | oui | Voir ci-dessus |

Middlewares propres à l'application (basic-auth de recette, redirection www→apex, limitation
de débit) : à déclarer dans **ses** labels, nommés `${COMPOSE_PROJECT_NAME}-<quoi>` pour ne
pas entrer en collision avec un autre projet de l'hôte.

```yaml
# recette protégée, activée seulement si TRAEFIK_AUTH_USERS est renseignée
- "traefik.http.routers.${COMPOSE_PROJECT_NAME}.middlewares=security-headers@file${TRAEFIK_AUTH_USERS:+,${COMPOSE_PROJECT_NAME}-auth}"
- "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-auth.basicauth.users=${TRAEFIK_AUTH_USERS}"
```

## 3. Base de données

- Hôte : `infra_mysql_8_0` (ou `infra_mariadb_11_3` si le profil tourne et que l'application
  l'a choisi). Port 3306, non publié sur l'hôte : passer par phpMyAdmin ou `docker exec`.
- Créer la base et un compte dédié :
  ```sql
  CREATE DATABASE `prod_monapp` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER 'monapp'@'%' IDENTIFIED BY '…';
  GRANT ALL ON `prod_monapp`.* TO 'monapp'@'%';
  ```
- Renommer une base vers la convention : `ops/sync-db-names.sh` (dump + reload, ancienne base
  conservée tant que `--drop-old` n'est pas passé).

## 4. Mail

- En local et en recette : `infra_mailer:1025`, tout est capturé, rien ne sort. Interface :
  `$MAILPIT_DOMAIN`.
- En prod : un **vrai** relais. Une application prod branchée sur Mailpit envoie ses mails dans
  le vide, sans erreur.

## 5. Check-list avant de dire « ça marche »

1. `docker compose config` de l'application ne montre aucune variable vide dans les labels.
2. `docker network inspect traefik` liste le conteneur HTTP du projet, et seulement lui.
3. `curl -I https://<domaine>` répond 200 ou 30x, pas 404 : un 404 Traefik = routeur absent
   (label manquant, variable vide, middleware inconnu → voir `RUNBOOK-incident.md`).
4. Les en-têtes `Strict-Transport-Security` et `X-Frame-Options` sont présents si
   `security-headers@file` est attaché.
5. Le mail de test arrive dans Mailpit (local) ou chez le destinataire (prod).
6. Le projet n'a **aucun** `container_name`, aucun `ports:` publié sur l'hôte, aucun service
   base/proxy/mail à lui.

## 6. Ce que le socle promet, et ce qu'il ne promet pas

Promis : les noms `infra_traefik`, `infra_mysql_8_0`, `infra_mariadb_11_3`, `infra_mailer`,
`infra_phpmyadmin` ; les réseaux `traefik`, `databases`, `mailer` ; les middlewares
`security-headers@file` et `security-headers-idp@file` ; l'entrypoint `websecure` ; le
résolveur `le` en prod.

Non promis : un port publié sur l'hôte pour SQL ; une version précise de Traefik au-delà de la
2.x ; qu'un middleware déclaré dans `dynamic/local/` existe aussi en `prod` (ils sont
indépendants par construction).
