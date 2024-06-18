.PHONY: help

up:
	(cd services/traefik2 && docker compose up -d)
	(cd services/mysql80 && docker compose up -d)
	(cd services/phpmyadmin && docker compose up -d)
	(cd services/mailhog && docker compose up -d)

down:
	(cd services/mailhog && docker compose down)
	(cd services/phpmyadmin && docker compose down)
	(cd services/mysql80 && docker compose down)
	(cd services/traefik2 && docker compose down)
