# PHP natif, sans framework : rien à migrer ; dépendances Composer si le projet en a.
# Chaque cible s'efface si .docker/make/project.mk la liste dans PROJECT_OVERRIDES (et la redéfinit).
ifeq ($(filter install,$(PROJECT_OVERRIDES)),)
install: ## dépendances PHP (composer.json présent)
	$(EXEC_PHP) sh -c 'if [ -f composer.json ]; then composer install --no-interaction $(if $(filter prod,$(ENV)),--no-dev --optimize-autoloader); fi'
endif

ifeq ($(filter deploy,$(PROJECT_OVERRIDES)),)
deploy: upbuild install ## prod : reconstruit, redémarre, dépendances, recrée nginx (config régénérée)
	$(RECREATE_NGINX)
endif
