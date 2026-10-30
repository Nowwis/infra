# Site branché sur le socle. `make help` liste les cibles ; le type (PROJECT_TYPE) et les
# services (COMPOSE_PROFILES) viennent de .docker/.env, les cibles propres au type de
# .docker/make/<type>.mk.
.DEFAULT_GOAL := help
ENV ?= dev

-include .docker/.env
export

COMPOSE_FILES := -f .docker/docker-compose.yml
ifeq ($(ENV),prod)
  COMPOSE_FILES := -f .docker/docker-compose.prod.yml
  # Alias redirigés : www.<domaine> (PROD_WWW_ALIAS=1) ou règle libre (TRAEFIK_ALIAS_RULE).
  ifneq ($(filter 1,$(PROD_WWW_ALIAS))$(if $(TRAEFIK_ALIAS_RULE),1),)
    COMPOSE_FILES += -f .docker/docker-compose.prod.www.yml
  endif
endif
# Services propres au projet (worker, broker, outil de dev…) : fichiers facultatifs du dépôt, jamais dans le
# modèle, ajoutés après les fichiers communs (local : docker-compose.project.yml, prod : docker-compose.prod.project.yml).
PROJECT_COMPOSE := .docker/docker-compose.$(if $(filter prod,$(ENV)),prod.)project.yml
COMPOSE_FILES += $(if $(wildcard $(PROJECT_COMPOSE)),-f $(PROJECT_COMPOSE))
# Local seulement : réglages du poste, jamais versionnés (.gitignore), ex. une route d'exposition temporaire.
ifneq ($(ENV),prod)
  COMPOSE_FILES += $(if $(wildcard .docker/docker-compose.override.yml),-f .docker/docker-compose.override.yml)
endif
DOCKER_COMPOSE := docker compose --env-file .docker/.env $(COMPOSE_FILES)
EXEC_PHP := $(DOCKER_COMPOSE) exec php
# La config nginx est générée au démarrage du conteneur depuis le fichier monté : `up --build` ne la
# recharge pas si elle seule a changé. Les cibles deploy recréent nginx après le redémarrage.
RECREATE_NGINX := $(DOCKER_COMPOSE) up -d --force-recreate --no-deps nginx

# Réglages et cibles propres au projet (facultatif), AVANT les cibles communes et le type : ses variables
# (SF_* de deploy.mk…) doivent être posées quand le fichier du type est lu. Les fichiers communs restent
# identiques au modèle. Pour remplacer une cible du modèle, le projet la liste dans PROJECT_OVERRIDES
# (ex. PROJECT_OVERRIDES := clean-cache init-dev) et la définit : la recette du modèle n'est alors pas lue.
PROJECT_OVERRIDES :=
-include .docker/make/project.mk

.PHONY: help up upbuild down ps logs exec deploy

ifeq ($(filter help,$(PROJECT_OVERRIDES)),)
help: ## cette aide
	@grep -HE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -v ov=" $(PROJECT_OVERRIDES) " \
	  '{ split($$0, a, ":"); i = index($$0, "## ") } \
	   a[1] != ".docker/make/project.mk" && index(ov, " " a[2] " ") { next } \
	   { printf "  \033[36m%-12s\033[0m %s\n", a[2], substr($$0, i + 3) }'
endif

ifeq ($(filter up,$(PROJECT_OVERRIDES)),)
up: ## démarre les services du type (ENV=prod pour la prod)
	$(DOCKER_COMPOSE) up -d --remove-orphans
endif

ifeq ($(filter upbuild,$(PROJECT_OVERRIDES)),)
upbuild: ## reconstruit les images puis démarre
	$(DOCKER_COMPOSE) up -d --remove-orphans --build
endif

ifeq ($(filter down,$(PROJECT_OVERRIDES)),)
down: ## arrête le site (le socle et la base restent)
	$(DOCKER_COMPOSE) down
endif

ifeq ($(filter ps,$(PROJECT_OVERRIDES)),)
ps: ## état des conteneurs du site
	$(DOCKER_COMPOSE) ps
endif

ifeq ($(filter logs,$(PROJECT_OVERRIDES)),)
logs: ## journaux (make logs S=php pour un autre service que nginx)
	$(DOCKER_COMPOSE) logs -f --tail=100 $(or $(S),nginx)
endif

ifeq ($(filter exec,$(PROJECT_OVERRIDES)),)
exec: ## shell dans le conteneur php
	$(EXEC_PHP) bash
endif

# Cibles propres au type ; chacune s'efface si le projet la liste dans PROJECT_OVERRIDES.
-include .docker/make/$(PROJECT_TYPE).mk
