# WordPress.

wp: ## wp-cli (make wp A="plugin list")
	$(DOCKER_COMPOSE) exec php sh -c 'command -v wp >/dev/null || { echo "wp-cli absent : make wp-install"; exit 1; }; wp $(A)'

wp-install: ## installe wp-cli dans le conteneur php (une fois par image)
	$(DOCKER_COMPOSE) exec -u root php sh -c 'curl -sSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x /usr/local/bin/wp'

deploy: upbuild ## prod : reconstruit et redémarre (le code est déjà à jour par git)
