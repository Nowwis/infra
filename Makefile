.PHONY: help up down console-deploy

up:
	docker compose up -d

down:
	docker compose down

# Déploie la console depuis la source (checkout principal, sur main) :
# récupère main, (re)génère les unités systemd + le secret basic-auth, redémarre les services.
# Le service web sert les fichiers en direct -> une MAJ de l'UI ne nécessite que le pull.
console-deploy:
	git pull --ff-only
	set -a; [ -f console/console.env ] && . ./console/console.env; set +a; bin/console-install
	-systemctl --user restart console-web.service
	@echo "OK. Si la route Traefik (dynamic_conf.local.yaml) a changé dans ce pull, applique-la : docker restart infra_traefik"
