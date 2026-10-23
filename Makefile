# Socle d'hébergement — pilotage. `make help` liste les cibles ; docs/COMMANDS.md les combine.
.DEFAULT_GOAL := help
SHELL := /bin/bash
# make up PROFILES=mariadb → démarre aussi le second moteur. Profils permanents d'un hôte :
# COMPOSE_PROFILES=mariadb,gatus dans .env (lu par docker compose et par make check).
PROFILES ?=
COMPOSE := docker compose $(foreach p,$(PROFILES),--profile $(p))

.PHONY: help networks check up down ps logs traefik-config deploy test certs

help: ## cette aide
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

networks: ## crée une fois les réseaux externes traefik, databases, mailer
	@for n in traefik databases mailer; do docker network inspect $$n >/dev/null 2>&1 || docker network create $$n; done
	@docker network ls --format '{{.Name}}' | grep -E '^(traefik|databases|mailer)$$'

check: ## vérifie .env, la config Traefik de l'ENV, les réseaux, les hash, la config gatus — avant tout déploiement
	PROFILES="$(PROFILES)" bin/infra-check

up: check ## démarre le socle (PROFILES=mariadb, PROFILES=gatus, ou COMPOSE_PROFILES dans .env)
	$(COMPOSE) up -d

down: ## arrête le socle (les réseaux externes et les données restent)
	$(COMPOSE) down

ps: ## état des conteneurs du socle
	$(COMPOSE) ps

logs: ## journaux du reverse proxy (make logs S=mysql pour un autre service)
	$(COMPOSE) logs -f --tail=100 $(or $(S),reverse-proxy)

traefik-config: check ## applique un changement de config STATIQUE ou de volumes (recrée le seul reverse proxy)
	$(COMPOSE) up -d --force-recreate reverse-proxy
	@echo "La config DYNAMIQUE (configuration/traefik2/config/dynamic/<ENV>/) n'a pas besoin de ça : le dossier est monté, un git pull est rechargé à chaud."

deploy: ## sur un hôte : git pull --ff-only, check, puis recréation du reverse proxy si sa config statique a changé
	@before=$$(git rev-parse HEAD); git pull --ff-only; after=$$(git rev-parse HEAD); \
	$(MAKE) --no-print-directory check || { echo "make check en échec : rien n'est recréé (le git pull est fait)."; exit 1; }; \
	if git diff --quiet $$before $$after -- compose.yml configuration/traefik2/config/traefik.*.yaml; then \
	  echo "compose.yml et la config statique inchangés : rien à recréer (dynamique rechargée à chaud)."; \
	else \
	  echo "compose.yml ou config statique modifiés : recréation du reverse proxy."; $(MAKE) --no-print-directory traefik-config; \
	fi; \
	if $(COMPOSE) config --services 2>/dev/null | grep -qx gatus; then \
	  echo "profil gatus actif : mise à jour du service si compose.yml a changé (sa liste se recharge seule)."; $(COMPOSE) up -d gatus; \
	fi

certs: ## local : génère le certificat mkcert *.docker.test dans configuration/traefik2/certs
	cd configuration/traefik2 && mkcert -cert-file certs/docker.localhost.pem -key-file certs/docker.localhost-key.pem "docker.test" "*.docker.test" "docker.localhost" "*.docker.localhost"

test: ## suite bats (bin/infra-check)
	bats tests/
