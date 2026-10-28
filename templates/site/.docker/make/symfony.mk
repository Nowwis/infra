# Symfony.
CONSOLE := $(EXEC_PHP) php bin/console
EXEC_NODEJS := $(DOCKER_COMPOSE) exec nodejs

install: ## dépendances PHP et assets publics
	$(EXEC_PHP) composer install --no-interaction $(if $(filter prod,$(ENV)),--no-dev --optimize-autoloader)
	$(CONSOLE) assets:install --symlink

migrate: ## migrations Doctrine
	$(CONSOLE) doctrine:migrations:migrate -n --allow-no-migration --env=$(ENV)

clean-cache: ## vide le cache
	$(CONSOLE) cache:clear --env=$(ENV)

yarn: ## shell dans le conteneur nodejs
	$(EXEC_NODEJS) bash

yarn-dev: ## build unique des assets en mode dev (~10 s)
	$(EXEC_NODEJS) yarn dev

yarn-build: ## build de production minifié, avant une PR qui touche assets/
	$(EXEC_NODEJS) yarn build

init-dev: ## recrée la base locale, migre, charge les fixtures
	$(CONSOLE) doctrine:database:drop --if-exists --force
	$(CONSOLE) doctrine:database:create
	$(CONSOLE) doctrine:migrations:migrate -n --allow-no-migration
	$(CONSOLE) doctrine:fixtures:load -n

# Déploiement (`make ENV=prod deploy`, lancé sur le serveur après la synchronisation du code). Si le dépôt porte le
# post_deploy commun .docker/make/deploy.mk (copie à l'identique d'une référence partagée : composer --no-dev, migrations,
# cache, assets, workers, test de fumée), c'est lui qui définit `deploy` ; sinon, cible minimale ci-dessous.
ifneq ($(wildcard .docker/make/deploy.mk),)
include .docker/make/deploy.mk
else
deploy: upbuild install migrate clean-cache
endif
deploy: ## prod : post_deploy (deploy.mk commun s'il est là, sinon reconstruit, dépendances, migrations, cache)
