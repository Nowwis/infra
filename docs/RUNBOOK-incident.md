# Runbook — incidents

Dans l'ordre où ils arrivent le plus souvent. Première commande dans tous les cas :

```bash
cd ~/infra && make ps && make logs | tail -50
```

## Tous les sites répondent 404

Un 404 **servi par Traefik** (page brute « 404 page not found ») signifie : aucun routeur ne
correspond. Si c'est tous les sites à la fois, les routeurs ont été supprimés en bloc. Causes,
par fréquence :

1. **Un middleware référencé n'existe plus.** Un routeur qui pointe sur un middleware inconnu
   est supprimé, pas dégradé. Vérifier que `configuration/traefik2/config/dynamic/<ENV>/`
   contient bien le fichier qui déclare les middlewares, et que c'est **le dossier** qui est
   monté (`docker inspect infra_traefik --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'`
   doit montrer `.../dynamic/<ENV> -> /etc/traefik/dynamic`). Si un fichier est monté à la
   place, le conteneur lit un inode périmé : `make traefik-config`.
2. **Le tableau de bord le dit.** `https://$MONITORING_DOMAIN` → HTTP → Routers : les routeurs
   en erreur sont listés avec la cause (« middleware "x@file" does not exist »).
3. **Journal** : `make logs | grep -iE 'error|middleware|router'`.

Un 404 **servi par l'application** (page du framework) est un problème applicatif, pas socle.

## Un seul site en 404

Le routeur de ce site est absent. Dans l'ordre :

1. `docker compose config` **dans le dossier de l'application** : une variable vide dans un
   label (`Host(``)`, `middlewares=`) rend le routeur invalide.
2. Le conteneur porte `traefik.enable=true` et est sur le réseau `traefik`
   (`docker network inspect traefik | grep <nom>`).
3. Tableau de bord → Routers → chercher le nom du projet.

## 502 Bad Gateway sur un site

Traefik joint le routeur mais pas le conteneur :

1. Conteneur arrêté ou en redémarrage : `docker ps -a | grep <projet>`.
2. Service sur plusieurs réseaux **sans** `traefik.docker.network=traefik` : Traefik choisit
   une IP d'un réseau qu'il n'a pas. Ajouter le label.
3. Mauvais port : `services.<s>.loadbalancer.server.port` ≠ port d'écoute réel.

## phpMyAdmin / Mailpit / tableau de bord en 404

La variable `*_USERS` ou `*_MIDDLEWARE` correspondante est vide : middleware invalide,
routeur supprimé. `make check` le dit. Renseigner, puis `docker compose up -d <service>`.

## « Mon mot de passe ne marche plus » sur un basic-auth

Hash bcrypt avec `$` non doublé dans `.env` : Compose a tronqué le hash en silence.
`docker compose config | grep -A0 'basicauth.users'` montre la valeur réellement posée ; si
elle finit par `$2y$05`, c'est ça. Réécrire avec `$$` (voir `.env.example`), puis recréer le
service. `make check` détecte désormais le cas.

## Certificat Let's Encrypt absent ou expiré

1. `make logs | grep -i acme` : « unable to obtain ACME certificate » + cause.
2. Causes : port 80 non joignable depuis Internet (pare-feu, CDN en mode strict), DNS qui ne
   pointe pas (encore) sur le serveur, limite de débit Let's Encrypt atteinte (5 échecs par
   heure, 50 certificats par domaine et par semaine).
3. `letsencrypt/acme.json` doit appartenir à root en `600`. Ne pas le supprimer pour « forcer »
   : c'est précisément ce qui atteint la limite.
4. Un domaine applicatif sans certificat : son routeur manque `tls.certresolver=le`, ou son
   DNS ne pointe pas ici.

## Le journal d'accès remplit le disque

`du -sh ~/infra/configuration/traefik2/logs`. Le cron de rotation est-il posé (`crontab -l`) et
a-t-il tourné (`logs/rotate.log`) ? Forcer : `MAXSIZE=0 ~/infra/configuration/traefik2/rotate-logs.sh`.
Si le fichier a été supprimé à la main alors que Traefik l'avait ouvert, l'espace n'est libéré
qu'après `docker kill -s USR1 infra_traefik`.

## Après un `git pull`, plus rien ne marche

1. `make check` : il dit ce qui manque (variable introduite par la mise à jour).
2. `CHANGELOG.md` : l'entrée annonce-t-elle une recréation ? `make traefik-config`.
3. Retour arrière : `RUNBOOK-deploy.md` §4.

## MySQL ne démarre pas

`make logs S=mysql`. Causes vues : permissions de `datas/mysql_8_0/datas` (doit appartenir à
l'uid du conteneur, 999), disque plein, arrêt brutal (InnoDB répare seul au redémarrage, laisser
finir). Ne jamais supprimer `datas/` pour « repartir propre » sans dump préalable.

## Lire le journal d'accès

```bash
tail -f configuration/traefik2/logs/access.log | jq -r '[.time, .ClientHost, .request_Cf_Connecting_Ip // "-", .RequestHost, .RequestMethod, .RequestPath, .DownstreamStatus, .Duration/1e6|floor] | @tsv'
```
Le champ `Cf-Connecting-Ip` porte l'IP réelle quand un CDN est devant ; `ClientHost` est alors
l'IP du CDN.

## Quand c'est réparé

Noter dans `DECISIONS.md` si la réparation a changé une règle, et dans `CHANGELOG.md` si elle a
changé un fichier versionné. Un incident qui ne laisse pas de trace se reproduit.
