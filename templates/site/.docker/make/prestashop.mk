# PrestaShop 9.
CONSOLE := $(EXEC_PHP) php bin/console

install: ## dépendances PHP
	$(EXEC_PHP) composer install --no-interaction

clean-cache: ## vide le cache de l'environnement courant
	$(EXEC_PHP) sh -c 'rm -rf var/cache/$(if $(filter prod,$(ENV)),prod,dev)/*'

deploy: upbuild clean-cache ## prod : reconstruit, redémarre, vide le cache
