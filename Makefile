.PHONY: help up down dash-deploy

up:
	docker compose up -d

down:
	docker compose down

# Déploie le dashboard depuis la source (à lancer sur le checkout principal, sur main) :
# récupère main, (re)génère l'unit systemd + le secret basic-auth, redémarre le service.
# Le service sert les fichiers en direct -> une MAJ code (UI/collecteur) ne nécessite que le pull.
dash-deploy:
	git pull --ff-only
	set -a; [ -f dashboard/dashboard.env ] && . ./dashboard/dashboard.env; set +a; bin/wt-dash-install
	-systemctl --user restart wt-dashboard.service
	@echo "OK. Si la route Traefik (dynamic_conf.local.yaml) a changé dans ce pull, applique-la : docker restart infra_traefik"
