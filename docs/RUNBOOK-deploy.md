# Runbook — installer et mettre à jour un hôte

Convention : le dépôt est cloné en **`~/infra`** sur chaque hôte, et c'est ce clone que les
unités systemd et le cron appellent. Sur une machine de développement on peut avoir en plus un
checkout de travail ailleurs ; `~/infra` reste sur `main`.

## 1. Installation d'un serveur (`ENV=prod`)

Prérequis : Docker Engine + Compose v2, un utilisateur non-root membre du groupe `docker`, les
ports 80 et 443 ouverts depuis Internet, les enregistrements DNS des trois domaines du socle
(`MONITORING_DOMAIN`, `PMA_DOMAIN`, `MAILPIT_DOMAIN`) pointant sur le serveur.

```bash
git clone <url> ~/infra && cd ~/infra
cp .env.example .env
```

Renseigner `.env` :

| Variable | Valeur prod |
|---|---|
| `ENV` | `prod` |
| `TRAEFIK_DASHBOARD_INSECURE` | `false` |
| `TRAEFIK_MONITORING_MIDDLEWARE` | `auth` |
| `TRAEFIK_DASHBOARD_USERS`, `TRAEFIK_MAILPIT_USERS`, `TRAEFIK_PHPMYADMIN_USERS` | trois hash **différents** ; bcrypt avec `$$` (voir `.env.example`) |
| `TRAEFIK_ENTRYPOINT` | `websecure` |
| `TRAEFIK_CERTRESOLVER` | `le` |
| `TRAEFIK_BIND` | vide |
| `LETSENCRYPT_EMAIL` | une adresse lue |
| `MYSQL_ROOT_PASSWORD` | généré, long |
| `TRAEFIK_MAILPIT_MIDDLEWARE` | `mailpit-auth` |
| `*_DOMAIN` | les vrais sous-domaines |

```bash
make networks
make check                 # doit afficher « infra-check : OK (prod) »
make up
make ps                    # cinq conteneurs Up (quatre sans le profil mariadb)
make logs                  # attendre « Certificates obtained » ; en cas d'erreur ACME voir RUNBOOK-incident
curl -I https://$PMA_DOMAIN       # 401
curl -I https://$MAILPIT_DOMAIN   # 401
curl -I https://$MONITORING_DOMAIN # 401
```

Rotation des journaux :

```bash
( crontab -l 2>/dev/null; echo '0 */6 * * * ~/infra/configuration/traefik2/rotate-logs.sh >> ~/infra/configuration/traefik2/logs/rotate.log 2>&1' ) | crontab -
```

Puis déployer les applications (chacune : `docker compose up -d` dans son dossier, voir
`CONTRACT.md`).

## 2. Installation d'un poste ou d'un labo (`ENV=local`)

```bash
mkcert -install
git clone <url> ~/infra && cd ~/infra
cp .env.example .env       # ENV=local, TRAEFIK_CERTRESOLVER vide, TRAEFIK_BIND=127.0.0.1: ou <ip-privée>:
make networks && make certs && make up
```

Résolution de `*.docker.test` : entrée hosts par domaine, ou un résolveur local (dnsmasq,
systemd-resolved avec un domaine de recherche, DNS du VPN). Le certificat mkcert est valable
sur toute machine qui a installé l'autorité mkcert du poste (`mkcert -CAROOT`).

`TRAEFIK_BIND` : sur un poste, `127.0.0.1:` ; sur une machine partagée via VPN, l'IP de
l'interface VPN suivie de `:`. **Jamais vide sur une machine joignable depuis Internet avec
`ENV=local`** : le tableau de bord y est ouvert et Mailpit expose tous les mails capturés.

## 3. Mise à jour d'un hôte

1. Lire l'entrée du `CHANGELOG.md` correspondant aux commits à récupérer. Elle dit si une
   **action serveur** est requise : nouvelle variable `.env`, recréation du proxy, cron.
2. Poser les nouvelles variables dans `.env` **avant** de tirer.
3. `cd ~/infra && make deploy`. La cible tire en `--ff-only` (refuse si le clone a divergé),
   lance `check`, et recrée le reverse proxy seulement si `compose.yml` ou la config statique
   ont changé.
4. Vérifier : `make ps`, les trois `curl -I` ci-dessus, et un site applicatif.

Si `git pull --ff-only` refuse : le clone a été modifié localement. `git status`, `git stash`
ou `git checkout -- <fichier>` après avoir regardé ce qui diffère, puis recommencer. **Ne jamais
éditer la config à la main sur un hôte** : tout changement passe par une PR, sinon le prochain
déploiement l'écrase ou refuse de passer.

## 4. Retour arrière

| Ce qui a cassé | Retour |
|---|---|
| Config dynamique (`dynamic/<ENV>/`) | `git revert <commit>` puis `git pull` sur l'hôte : rechargé à chaud |
| Config statique, `compose.yml` | `git revert <commit>`, `make deploy` (recrée le proxy) |
| Image (nouvelle version cassée) | épingler l'ancienne version dans `compose.yml`, `docker compose up -d <service>` ; **jamais pour MySQL après un changement de série** (ci-dessous) |
| Tout | `git checkout <tag-ou-commit-connu> && make traefik-config && docker compose up -d` |

Les données (`datas/`, `letsencrypt/`) ne sont jamais touchées par ces opérations.

### MySQL : changer de série (8.0 → 8.4)

Le premier démarrage d'une nouvelle série met à niveau le dictionnaire de données **en place**.
Ensuite l'ancienne série refuse de démarrer sur ces données (`Cannot downgrade from 80413 to
80046`, arrêt, redémarrage en boucle avec `restart: always`). Le seul retour arrière est la
restauration d'un dump logique, ou d'une copie à froid prise juste avant. `make check` refuse donc
la montée tant que `MYSQL_UPGRADE_CONFIRMED=1` n'est pas posé, et refuse toujours la descente.

Mesuré sur un hôte local (4,6 Go de datadir, ~2 350 tables) : mise à niveau en place 15 s,
recréation du conteneur jusqu'à « ready for connections » 17 s, copie à froid 20 s.

**Avant (lecture seule, sans coupure)**

```bash
cd ~/infra
sql() { docker exec -i infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N'; }
echo "SELECT VERSION()" | sql                      # 8.4 exige 8.0.37 ou plus
echo "SELECT user,host FROM mysql.user WHERE plugin='mysql_native_password'" | sql   # doit être vide
df -h . && du -sh datas/mysql_8_0/datas            # place pour la copie à froid
docker compose pull mysql                          # l'image est là avant la coupure
```

Un compte encore en `mysql_native_password` ne se connecte plus en 8.4 (plugin désactivé). Le
passer avant, avec le mot de passe que l'application utilise déjà :
`ALTER USER '<compte>'@'%' IDENTIFIED WITH caching_sha2_password BY '<mot de passe de l application>';`
À défaut, transitoire : `mysql_native_password=ON` dans un `.cnf` de `configuration/mysql_8_0/conf.d/`
(section `[mysqld]`), par PR, retiré dès que le compte est migré.

**Dump logique (sans coupure)**

```bash
d=~/mysql-upgrade-$(date +%F) && mkdir -p "$d" && chmod 700 "$d"
dbs=$(echo "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema')" | sql | tr '\n' ' ')
docker exec infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --triggers --events --hex-blob --no-tablespaces --set-gtid-purged=OFF --databases '"$dbs" | gzip > "$d/databases.sql.gz"
{ echo "SET SESSION print_identified_with_as_hex=ON;"
  echo "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user WHERE user NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema')" | sql \
    | while read -r u; do echo "SHOW CREATE USER $u; SHOW GRANTS FOR $u;"; done
} | sql | sed 's/$/;/' > "$d/accounts.sql"
zcat "$d/databases.sql.gz" | tail -1                # « -- Dump completed on … »
```

`accounts.sql` contient les empreintes des mots de passe : il reste sur l'hôte, en `700`.

**Montée (coupure ~1 min)**

```bash
git pull --ff-only                                  # make deploy s'arrête sur le contrôle MySQL : attendu
docker stop -t 120 infra_mysql_8_0
docker run --rm -v "$PWD/datas/mysql_8_0:/m" alpine cp -a /m/datas /m/datas.8.0-$(date +%F)   # copie à froid (fichiers de l uid 999, sans sudo)
MYSQL_UPGRADE_CONFIRMED=1 make check
docker compose up -d --no-deps mysql
docker logs -f infra_mysql_8_0                      # « Server upgrade from '800xx' to '804xx' completed », puis « ready for connections »
```

**Vérifier** : `SELECT VERSION()`, aucune ligne `[ERROR]` dans `docker logs infra_mysql_8_0`, chaque
application (page servie, aucune erreur SQL dans ses journaux), connexion phpMyAdmin, un dump de
contrôle avec la commande de l'outil de sauvegarde, puis `ops/backup-check/restore-test.sh` sur ce
dump. Garder la copie à froid et le dossier de dump au moins une semaine.

**Retour arrière**

1. Sans perte des écritures faites depuis la montée (supporté par MySQL pour un retour arrière,
   tant qu'aucune fonction propre à la nouvelle série n'a servi) : dumper la nouvelle série comme
   ci-dessus dans un autre dossier, arrêter le conteneur, mettre `datas/mysql_8_0/datas` de côté
   (`mv`, jamais `rm`), remettre l'ancienne série dans `compose.yml` (revert par PR ; en urgence
   `git checkout <commit d avant> -- compose.yml`, à remettre ensuite), `docker compose up -d --no-deps mysql`
   (datadir vide : initialisé avec `MYSQL_ROOT_PASSWORD`), puis charger `accounts.sql` et
   `databases.sql.gz`. Mesuré : ~8 min pour 2 Go de données.
2. Plus rapide, en perdant les écritures depuis la montée : arrêter, mettre le datadir de côté,
   remettre la copie à froid à sa place, ancienne série dans `compose.yml`, démarrer.

## 5. Ce qui ne doit jamais être fait sur un hôte

- Éditer `compose.yml` ou `configuration/` à la main (voir §3).
- Lancer `docker compose down -v` : le `-v` détruit les volumes nommés ; le socle n'en a pas,
  mais l'habitude est mauvaise.
- Supprimer `letsencrypt/acme.json` sans raison : Let's Encrypt limite les émissions par
  domaine et par semaine.
- Mettre `TRAEFIK_PHPMYADMIN_USERS` vide « pour tester » : phpMyAdmin passe en 404, pas en
  accès libre, c'est voulu ; mais on oublie ensuite pourquoi il ne répond plus.
