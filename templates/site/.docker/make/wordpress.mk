# WordPress. Le cœur n'est pas versionné : `make core` le télécharge (à la version du serveur).
#
# Copies depuis le serveur (db-pull, files-pull) : lecture seule côté serveur, rien n'y est écrit.
# Variables, vides par défaut, à poser dans .docker/.env ou en ligne de commande :
#   REMOTE       hôte SSH du serveur (alias de ~/.ssh/config), ex. REMOTE=prod-web
#   REMOTE_PROD  chemin de l'installation WordPress sur le serveur, ex. /var/www/example.com
#   PROD_URL     URL publique du site, ex. https://example.com
#   LOCAL_URL    URL locale ; vide = https://$(COMPOSE_PROJECT_DOMAIN)
#   WP_VERSION   version du cœur pour `make core` ; vide = dernière version
#   WP_LOCALE    langue du cœur pour `make core` ; vide = en_US
#   WP_LOCAL_DEACTIVATE  extensions à désactiver après import (pare-feu, cache de pages…)
# Le préfixe des tables est WORDPRESS_TABLE_PREFIX (.docker/.env) : celui de la base importée.
# wp-cli doit être installé sur le serveur (`wp db export`).
#
# Ne jamais rendre une page par PHP CLI sur un serveur pour la « tester » (php index.php,
# wp eval…) : les constructeurs de pages y écrivent un cache (CSS, rendu) calculé hors requête
# HTTP, faux, qui est ensuite servi aux visiteurs. Tester avec curl sur l'URL publique.

REMOTE      ?=
REMOTE_PROD ?=
PROD_URL    ?=
LOCAL_URL   ?=
WP_VERSION  ?=
WP_LOCALE   ?=
WP_LOCAL_DEACTIVATE ?=
DB_ROOT_CONTAINER ?= infra_mysql_8_0

WP_LOCAL_URL := $(or $(LOCAL_URL),https://$(COMPOSE_PROJECT_DOMAIN))
# Hôte seul (sans schéma) pour remplacer aussi les URL relatives au protocole (//example.com).
PROD_HOST    := $(patsubst http://%,%,$(patsubst https://%,%,$(PROD_URL)))
LOCAL_HOST   := $(patsubst http://%,%,$(patsubst https://%,%,$(WP_LOCAL_URL)))
SSH          := ssh -o BatchMode=yes
MYSQL_ROOT   := docker exec -i $(DB_ROOT_CONTAINER) sh -c 'exec mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" "$$@"' sh
SEARCH_REPLACE := --all-tables-with-prefix --precise --skip-columns=guid --report-changed-only

.PHONY: wp core wp-config db-create db-pull files-pull cache-purge check-remote

wp: ## wp-cli (make wp A="plugin list")
	$(EXEC_PHP) wp $(A)

core: ## télécharge le cœur WordPress (WP_VERSION, WP_LOCALE) sans toucher wp-content
	$(EXEC_PHP) wp core download --skip-content --force \
	  $(if $(WP_VERSION),--version=$(WP_VERSION)) $(if $(WP_LOCALE),--locale=$(WP_LOCALE))

wp-config: ## installe la configuration locale (.docker/wp-config.local.php → wp-config.php)
	cp .docker/wp-config.local.php wp-config.php

db-create: ## crée la base et le compte locaux (WORDPRESS_DB_*) sur la base du socle
	@test -n "$(WORDPRESS_DB_NAME)" -a -n "$(WORDPRESS_DB_USER)" || { echo "WORDPRESS_DB_NAME / WORDPRESS_DB_USER vides (.docker/.env)"; exit 2; }
	echo "CREATE DATABASE IF NOT EXISTS \`$(WORDPRESS_DB_NAME)\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; \
	CREATE USER IF NOT EXISTS '$(WORDPRESS_DB_USER)'@'%' IDENTIFIED BY '$(WORDPRESS_DB_PASSWORD)'; \
	GRANT ALL ON \`$(WORDPRESS_DB_NAME)\`.* TO '$(WORDPRESS_DB_USER)'@'%';" | $(MYSQL_ROOT)

check-remote:
	@test -n "$(REMOTE)" -a -n "$(REMOTE_PROD)" || { echo "REMOTE et REMOTE_PROD sont requis (voir .docker/make/wordpress.mk)"; exit 2; }

db-pull: check-remote db-create ## base du serveur → locale (flux, rien écrit sur le serveur), search-replace, purge
	@test -n "$(PROD_URL)" || { echo "PROD_URL est requis pour le search-replace"; exit 2; }
	$(SSH) $(REMOTE) "cd '$(REMOTE_PROD)' && wp db export - --single-transaction --quick" \
	  | $(MYSQL_ROOT) $(WORDPRESS_DB_NAME)
	$(EXEC_PHP) wp search-replace '$(PROD_URL)' '$(WP_LOCAL_URL)' $(SEARCH_REPLACE)
	$(EXEC_PHP) wp search-replace '//$(PROD_HOST)' '//$(LOCAL_HOST)' $(SEARCH_REPLACE)
	$(if $(WP_LOCAL_DEACTIVATE),$(EXEC_PHP) wp plugin deactivate $(WP_LOCAL_DEACTIVATE) --quiet || true)
	$(MAKE) --no-print-directory cache-purge

files-pull: check-remote ## uploads et langues du serveur → local (rsync, lecture seule côté serveur)
	rsync -az --delete -e "$(SSH)" $(REMOTE):$(REMOTE_PROD)/wp-content/uploads/ wp-content/uploads/
	rsync -az --delete -e "$(SSH)" $(REMOTE):$(REMOTE_PROD)/wp-content/languages/ wp-content/languages/

# Après tout import de base : les caches (objet, transients, CSS générés par un constructeur de
# pages) contiennent encore les URL et l'état du serveur.
cache-purge: ## vide les caches WordPress et ceux des constructeurs de pages actifs
	$(EXEC_PHP) wp cache flush --quiet || true
	$(EXEC_PHP) wp transient delete --all --quiet || true
	$(EXEC_PHP) sh -c 'if wp plugin is-active elementor 2>/dev/null; then wp elementor flush-css; fi' || true

deploy: upbuild ## prod : reconstruit et redémarre (le code est déjà à jour par git)
