# PrestaShop 9.
# Chaque cible s'efface si .docker/make/project.mk la liste dans PROJECT_OVERRIDES (et la redéfinit).
CONSOLE := $(EXEC_PHP) php bin/console

ifeq ($(filter install,$(PROJECT_OVERRIDES)),)
install: ## dépendances PHP
	$(EXEC_PHP) composer install --no-interaction
endif

ifeq ($(filter clean-cache,$(PROJECT_OVERRIDES)),)
# PrestaShop choisit var/cache/dev ou var/cache/prod selon _PS_MODE_DEV_, pas selon ENV : les deux sont vidés.
# Les dossiers restent, avec leur .gitkeep / index.php éventuels.
clean-cache: ## vide le cache (var/cache/dev et var/cache/prod)
	$(EXEC_PHP) sh -c 'for d in var/cache/dev var/cache/prod; do [ -d "$$d" ] || continue; find "$$d" -mindepth 1 -maxdepth 1 ! -name .gitkeep ! -name index.php -exec rm -rf {} +; done'
endif

ifeq ($(filter deploy,$(PROJECT_OVERRIDES)),)
deploy: upbuild clean-cache ## prod : reconstruit, redémarre, vide le cache, recrée nginx (config régénérée)
	$(RECREATE_NGINX)
endif
