# Décisions

Une entrée par arbitrage : date, décision, raison, ce que ça exclut. Les entrées antérieures à
la création de ce dépôt résument ce qui a été appris sur une version précédente du socle.

## Avant ce dépôt — ce qui a été appris

**Config dynamique montée en dossier, jamais en fichier.** Un bind mount de fichier garde
l'inode d'origine ; `git pull` écrit par renommage ; le conteneur lit un fichier périmé, les
middlewares disparaissent, tous les sites tombent en 404. Vécu, corrigé, documenté dans
`ARCHITECTURE.md` §2 et vérifié par `bin/infra-check`.

**phpMyAdmin derrière son propre basic-auth, échec fermé.** Il a été publié un temps sans
middleware, protégé par le seul login SQL. Décision : variable dédiée, obligatoire, vide = 404.

**En-têtes de sécurité en opt-in, pas sur l'entrypoint.** Un hôte héberge des sites aux besoins
contradictoires ; un en-tête global en casse au moins un.

**Deux moteurs, pas un.** Une application dont la production tourne en MariaDB doit se tester
sur MariaDB. Le second moteur est un profil, pas un service permanent.

**`$$` dans les hash.** Un hash bcrypt collé tel quel dans `.env` est tronqué en silence par
Compose. Plus personne ne se connecte, et le journal ne dit rien.

**Un tunnel public devant Traefik expose tout.** Un service d'exposition (type Funnel) placé
devant le reverse proxy d'un hôte `local` a rendu joignables depuis Internet tableau de bord,
phpMyAdmin et capteur de mails, via le seul en-tête `Host`. Règle : jamais.

## 2026-10 — Nouveau dépôt, historique neuf, contenu neutre

**Décision.** Recréer le dépôt du socle sans reprendre l'historique précédent, et n'y écrire
aucun nom de projet, d'hôte, de personne ni de ticket. Vocation : public.

**Pourquoi.** L'ancien dépôt mélangeait le socle, l'exploitation des serveurs et l'outillage
d'un poste de développement (hooks d'un assistant de code, console, tests) ; ses commits et
commentaires citaient des clients et des machines. Trier l'historique aurait coûté plus que de
repartir d'un contenu relu ligne à ligne.

**Ce que ça exclut.** Tout ce qui est propre à un poste ou à une personne : hooks, console
d'observation, scripts de session. Ils vivent dans un dépôt privé d'outillage. L'inventaire des
hôtes réels vit hors de ce dépôt (`HOSTS.md` n'est qu'un gabarit).

## 2026-10 — `make check` obligatoire et appelé par `up`, `traefik-config`, `deploy`

**Décision.** Aucune cible qui touche aux conteneurs ne s'exécute sans `bin/infra-check`.

**Pourquoi.** Les trois pannes connues du socle étaient des erreurs de déploiement détectables
avant de démarrer : variable vide, `$` non doublé, dossier dynamique absent.

**Ce que ça exclut.** `docker compose up -d` lancé à la main reste possible ; il n'est pas
documenté comme chemin normal.

## 2026-10 — Le clone vit en `~/infra` sur tout hôte

**Décision.** Chemin unique pour les unités systemd, le cron et les runbooks.

**Pourquoi.** L'ancien socle vivait à deux chemins différents selon la machine ; chaque script
ou unité ne marchait que sur l'une des deux.

## 2026-10 — `ENV` désigne le type d'hôte, pas l'environnement applicatif

**Décision.** `local` ou `prod`, rien d'autre. Un serveur `prod` héberge aussi des stacks de
recette ; la séparation se fait par les applications (préfixes de base, sous-domaines).

**Ce que ça exclut.** Un `ENV=staging` du socle : il n'y a pas de troisième jeu de config
Traefik qui le justifierait.

## 2026-10 — Journal d'accès en prod, rotation sans logrotate

**Décision.** JSON, en-têtes utiles conservés, rotation par un script `sh` et un cron de
l'utilisateur, `SIGUSR1` pour rouvrir.

**Pourquoi.** Tracer l'origine du trafic derrière un CDN ; certains hôtes n'ont ni `logrotate`
ni `sudo`.

## 2026-10 — MySQL hors du réseau `traefik`, niveau de log `INFO`

**Décision.** Le moteur SQL n'a rien à faire sur le réseau que Traefik route ; `DEBUG` en prod
remplit le disque et expose des détails inutiles.

## À trancher

- ~~Licence~~ : MIT, tranché le 2026-10-07.
- **Production des sauvegardes** : le socle fournit le contrôle, pas la sauvegarde. Décider si
  l'outillage de sauvegarde (dump chiffré, rotation, hors site) entre dans ce dépôt sous `ops/`
  ou reste séparé.
- **Mailpit en prod** : utile aux stacks de recette, inutile et trompeur pour une stack prod
  branchée dessus par erreur. Le garder derrière basic-auth, ou le réserver aux hôtes `local`.
