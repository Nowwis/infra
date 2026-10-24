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
  ifeq ($(PROD_WWW_ALIAS),1)
    COMPOSE_FILES += -f .docker/docker-compose.prod.www.yml
  endif
endif
DOCKER_COMPOSE := docker compose --env-file .docker/.env $(COMPOSE_FILES)
EXEC_PHP := $(DOCKER_COMPOSE) exec php

.PHONY: help up upbuild down ps logs exec deploy

help: ## cette aide
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## démarre les services du type (ENV=prod pour la prod)
	$(DOCKER_COMPOSE) up -d --remove-orphans

upbuild: ## reconstruit les images puis démarre
	$(DOCKER_COMPOSE) up -d --remove-orphans --build

down: ## arrête le site (le socle et la base restent)
	$(DOCKER_COMPOSE) down

ps: ## état des conteneurs du site
	$(DOCKER_COMPOSE) ps

logs: ## journaux (make logs S=php pour un autre service que nginx)
	$(DOCKER_COMPOSE) logs -f --tail=100 $(or $(S),nginx)

exec: ## shell dans le conteneur php
	$(EXEC_PHP) bash

-include .docker/make/$(PROJECT_TYPE).mk
