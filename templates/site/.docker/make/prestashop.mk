# PrestaShop 9.
# Chaque cible s'efface si .docker/make/project.mk la liste dans PROJECT_OVERRIDES (et la redéfinit).
CONSOLE := $(EXEC_PHP) php bin/console

ifeq ($(filter install,$(PROJECT_OVERRIDES)),)
install: ## dépendances PHP
	$(EXEC_PHP) composer install --no-interaction
endif

ifeq ($(filter clean-cache,$(PROJECT_OVERRIDES)),)
clean-cache: ## vide le cache de l'environnement courant
	$(EXEC_PHP) sh -c 'rm -rf var/cache/$(if $(filter prod,$(ENV)),prod,dev)/*'
endif

ifeq ($(filter deploy,$(PROJECT_OVERRIDES)),)
deploy: upbuild clean-cache ## prod : reconstruit, redémarre, vide le cache, recrée nginx (config régénérée)
	$(RECREATE_NGINX)
endif
