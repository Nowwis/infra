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

## 2026-10-22 — phpMyAdmin : image officielle `phpmyadmin:5.2`

**Décision.** L'image Docker officielle (`phpmyadmin`, dépôt library) remplace `phpmyadmin/phpmyadmin`.

**Pourquoi.** `phpmyadmin/phpmyadmin` n'a pas bougé depuis le 2025-10-08 (PHP 8.3.26) ; l'image officielle a
été reconstruite le 2026-10-22 avec PHP 8.3.36 (correctif PHP2Shell). Même phpMyAdmin (5.2.3), mêmes
variables `PMA_*`. Branche `5.2` figée, correctifs suivis par `docker compose pull`.

## 2026-10-22 — Traefik v3.7

**Décision.** Image `traefik:v3.7` (branche supportée), syntaxe de règles v3 par défaut, sans
`core.defaultRuleSyntax: v2`. `aliasHeadersStrategy: delete` sur les points d'entrée publics. Encodage des
caractères du chemin laissé aux valeurs par défaut (tout autorisé) pour ne rien casser côté WordPress /
PrestaShop ; à resserrer application par application si besoin.

**Pourquoi.** La 2.11 n'a plus de correctifs depuis le 2026-09-07. Inventaire des routeurs des hôtes avant
la montée : une seule règle en syntaxe v2, aucun HostRegexp, Headers(), ipWhiteList ni option d'en-têtes
retirée. Test sur un hôte local : mêmes codes HTTP qu'en 2.11.60 sur tous les routeurs.

**Ce que ça exclut.** Toute nouvelle règle `Host(`a`, `b`)` : écrire `Host(`a`) || Host(`b`)`.

## 2026-10-23 — Surveillance externe : Gatus en profil, config fournie par l'hôte

**Décision.** Gatus (`twinproduction/gatus:v5.37.0`), service `gatus` sous le profil `gatus`. La config
(ce que l'hôte surveille) n'est pas versionnée ici : elle vit hors du dépôt, dans le dossier
`GATUS_CONFIG_DIR` fourni par l'hôte (chemin absolu, monté en lecture seule sur `/config`, rechargé à
chaud). Historique en sqlite dans `datas/gatus/`, alertes Telegram (3 échecs de suite, retour à la
normale notifié), page d'état derrière un basic-auth dédié qui échoue fermé. Le dépôt ne livre qu'un
exemple neutre, `configuration/gatus/example/config.yaml`.

**Pourquoi.** Gratuit, configuration en fichiers, une seule image sans base externe, alerte Telegram
native. La liste surveillée nomme des domaines et des hôtes réels : elle n'a pas sa place dans un dépôt
public, d'où un dossier par hôte, hors du checkout. Un hôte ne surveille pas sa propre machine : une
panne de l'hôte emporterait l'alerte avec elle.

**Limites assumées.** Gatus ne détecte pas la SUPPRESSION d'un fichier de config : redémarrer le
conteneur dans ce cas. La config de chaque hôte n'est relue par aucune PR de ce dépôt : `make check`
la fait au moins charger par l'image avant chaque déploiement.

**Ce que ça exclut.** Un service SaaS de supervision ; une config Gatus dans le checkout (`make check`
refuse un `GATUS_CONFIG_DIR` relatif ou situé dans le dépôt) ; toute alerte qui ne passe pas par
`make check` (jeton Telegram vide = Gatus muet sans erreur ; config invalide = Gatus s'arrête au
rechargement). `make deploy` s'arrête désormais si `make check` échoue (il continuait).

## 2026-10-23 — MySQL 8.4 LTS, conteneur et chemins inchangés

**Décision.** Image `mysql:8.4` (branche LTS, correctifs seulement), montée en place depuis 8.0.
Le conteneur reste `infra_mysql_8_0`, les chemins `datas/mysql_8_0/` et `configuration/mysql_8_0/`
aussi. `make check` compare la série en service à celle de `compose.yml`.

**Pourquoi.** La 8.0 est en fin de vie. 8.0.37 et plus → 8.4 est un chemin de mise à niveau en place
supporté. Inventaire des hôtes avant la montée : tous les comptes en `caching_sha2_password`, aucune
option retirée en 8.4 dans la config ni dans la commande (conf.d vide), aucun nom de table ou de
colonne devenu réservé (`MANUAL`, `PARALLEL`, `QUALIFY`, `TABLESAMPLE`), aucune clé étrangère sur
une clé non unique, ni routine, trigger ou événement. Test sur un hôte local : mise à niveau sans
erreur, `CHECK TABLE` OK sur toutes les tables, applications et phpMyAdmin identiques, dumps 8.4
restaurés en 8.4 comme en 8.0.

**Ce que ça exclut.** Tout retour à 8.0 par simple changement d'image : la 8.0 refuse de démarrer
sur des données passées en 8.4 ; le retour passe par un dump (`docs/RUNBOOK-deploy.md` §4). Tout
nouveau compte en `mysql_native_password` (désactivé par défaut en 8.4). Renommer le conteneur
avec la version : c'est l'hôte de base de toutes les applications ; un nom neutre se fera par une
migration à part, avec un alias réseau le temps que les applications suivent.

**Défauts qui changent sans action** (rien n'est surchargé ici) : `innodb_io_capacity` 200 → 10000,
`innodb_flush_method` → `O_DIRECT`, `innodb_adaptive_hash_index` et `innodb_change_buffering`
désactivés, `innodb_log_buffer_size` 64 Mio, `restrict_fk_on_non_standard_key=ON` (une migration qui
créerait une clé étrangère sur un index non unique échoue désormais).

## À trancher

- ~~Licence~~ : MIT, tranché le 2026-10-07.
- **Production des sauvegardes** : le socle fournit le contrôle, pas la sauvegarde. Décider si
  l'outillage de sauvegarde (dump chiffré, rotation, hors site) entre dans ce dépôt sous `ops/`
  ou reste séparé.
- **Mailpit en prod** : utile aux stacks de recette, inutile et trompeur pour une stack prod
  branchée dessus par erreur. Le garder derrière basic-auth, ou le réserver aux hôtes `local`.
