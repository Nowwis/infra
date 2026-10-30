# Site statique : rien à installer ni à migrer.
# Chaque cible s'efface si .docker/make/project.mk la liste dans PROJECT_OVERRIDES (et la redéfinit).
ifeq ($(filter deploy,$(PROJECT_OVERRIDES)),)
deploy: upbuild ## prod : reconstruit, redémarre, recrée nginx (config régénérée)
	$(RECREATE_NGINX)
endif
