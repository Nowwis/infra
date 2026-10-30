# Symfony.
# Chaque cible s'efface si .docker/make/project.mk la liste dans PROJECT_OVERRIDES (et la redéfinit).
CONSOLE := $(EXEC_PHP) php bin/console
EXEC_NODEJS := $(DOCKER_COMPOSE) exec nodejs

ifeq ($(filter install,$(PROJECT_OVERRIDES)),)
install: ## dépendances PHP et assets publics
	$(EXEC_PHP) composer install --no-interaction $(if $(filter prod,$(ENV)),--no-dev --optimize-autoloader)
	$(CONSOLE) assets:install --symlink
endif

ifeq ($(filter migrate,$(PROJECT_OVERRIDES)),)
migrate: ## migrations Doctrine
	$(CONSOLE) doctrine:migrations:migrate -n --allow-no-migration --env=$(ENV)
endif

ifeq ($(filter clean-cache,$(PROJECT_OVERRIDES)),)
clean-cache: ## vide le cache
	$(CONSOLE) cache:clear --env=$(ENV)
endif

ifeq ($(filter yarn,$(PROJECT_OVERRIDES)),)
yarn: ## shell dans le conteneur nodejs
	$(EXEC_NODEJS) bash
endif

ifeq ($(filter yarn-dev,$(PROJECT_OVERRIDES)),)
yarn-dev: ## build unique des assets en mode dev (~10 s)
	$(EXEC_NODEJS) yarn dev
endif

ifeq ($(filter yarn-build,$(PROJECT_OVERRIDES)),)
yarn-build: ## build de production minifié, avant une PR qui touche assets/
	$(EXEC_NODEJS) yarn build
endif

ifeq ($(filter init-dev,$(PROJECT_OVERRIDES)),)
init-dev: ## recrée la base de l'ENV courant (dev ; ENV=test pour celle des tests), migre, fixtures
	$(CONSOLE) doctrine:database:drop --if-exists --force --env=$(ENV)
	$(CONSOLE) doctrine:database:create --env=$(ENV)
	$(CONSOLE) doctrine:migrations:migrate -n --allow-no-migration --env=$(ENV)
	$(CONSOLE) doctrine:fixtures:load -n --env=$(ENV)
endif

# Déploiement (`make ENV=prod deploy`, lancé sur le serveur après la synchronisation du code). Si le dépôt porte le
# post_deploy commun .docker/make/deploy.mk (copie à l'identique d'une référence partagée : composer --no-dev, migrations,
# cache, assets, workers, test de fumée), c'est lui qui définit `deploy` ; sinon, cible minimale ci-dessous.
ifeq ($(filter deploy,$(PROJECT_OVERRIDES)),)
ifneq ($(wildcard .docker/make/deploy.mk),)
include .docker/make/deploy.mk
else
deploy: upbuild install migrate clean-cache
	$(RECREATE_NGINX)
endif
deploy: ## prod : post_deploy (deploy.mk commun s'il est là, sinon reconstruit, dépendances, migrations, cache)
endif
