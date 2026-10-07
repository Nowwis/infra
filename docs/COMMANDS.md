# Commandes et combinaisons

Toutes les commandes du dépôt, puis les enchaînements par situation. Chaque commande se lance
depuis la racine du clone (`~/infra` sur un hôte).

## 1. Catalogue

### Makefile

| Cible | Fait | Quand |
|---|---|---|
| `make help` | Liste les cibles | |
| `make networks` | Crée `traefik`, `databases`, `mailer` s'ils manquent, puis les liste | Une fois par hôte ; sans danger à relancer |
| `make certs` | Génère le certificat mkcert `*.docker.test` dans `certs/` | Une fois en local ; après `mkcert -install` |
| `make check` | `bin/infra-check` : `.env`, variables, hash, config de l'ENV, réseaux, `compose config` | Avant tout `up`, `traefik-config`, `deploy` (ils l'appellent) |
| `make up [PROFILES=mariadb]` | `check` puis `docker compose up -d` | Premier démarrage, ou après un changement de `compose.yml` |
| `make down` | `docker compose down` : conteneurs et réseau interne ; **réseaux externes et `datas/` intacts** | Maintenance ; les applications perdent le proxy et SQL le temps de l'arrêt |
| `make ps` | État des conteneurs du socle | |
| `make logs [S=service]` | Journaux (`reverse-proxy` par défaut) | Diagnostic |
| `make traefik-config` | `check` puis recréation **du seul** reverse proxy | Après un changement de **config statique** (`traefik.<ENV>.yaml`) ou des volumes/ports |
| `make deploy` | `git pull --ff-only`, `check`, puis `traefik-config` **seulement si** `compose.yml` ou la config statique ont changé | Mise à jour d'un hôte |
| `make test` | `bats tests/` | Avant une PR |

### Scripts

| Script | Fait | Sécurité |
|---|---|---|
| `bin/infra-check` | La vérification pré-déploiement, détaillée en tête du fichier. `INFRA_SKIP_DOCKER=1` pour un hôte sans docker. | Lecture seule |
| `configuration/traefik2/rotate-logs.sh` | Rotation du journal d'accès au-delà de `MAXSIZE` (50 Mio), `ROTATIONS` (7) archives gzip, `SIGUSR1` à Traefik pour rouvrir le fichier | Lecture du dossier `logs/` uniquement |
| `ops/backup-check/weekly-restore-check.sh` | Dump ssh en lecture seule → restauration jetable → `CHECK TABLE` → taille vs médiane → alerte | Ne touche jamais le serveur contrôlé ; détruit son conteneur jetable |
| `ops/backup-check/restore-test.sh --backup-dir DIR` | Restaure des `*.sql.gz` sur un MySQL jetable, vérifie, mesure le RTO, écrit `restore-test-result.json` | Idem ; `--keep` garde le conteneur pour debug |
| `ops/sync-db-names.sh` | `--list` inventaire ; `old:new` dry-run ; `--apply` copie par dump/reload et réplique les droits ; `--drop-old` supprime l'ancienne | Non destructif sans `--drop-old` ; mot de passe jamais en argument |

### Docker Compose en direct (quand `make` ne suffit pas)

| Commande | Usage |
|---|---|
| `docker compose config` | Voir le compose résolu : **c'est là qu'un hash tronqué se voit** (`grep phpmyadmin-auth`) |
| `docker compose up -d <service>` | Recréer un seul service (`phpmyadmin`, `mailer`) après un changement de ses labels |
| `docker compose --profile mariadb up -d mariadb` | Démarrer le second moteur seul |
| `docker compose pull && docker compose up -d` | Mettre à jour les images (nouvelle version mineure de Traefik, phpMyAdmin) |
| `docker kill -s USR1 infra_traefik` | Faire rouvrir le journal d'accès (ce que fait `rotate-logs.sh`) |
| `docker exec -i infra_mysql_8_0 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'` | Shell SQL root sans mot de passe sur la ligne de commande |

## 2. Combinaisons par situation

### Nouveau poste de développement

```bash
mkcert -install
git clone <url> ~/infra && cd ~/infra
cp .env.example .env && $EDITOR .env        # ENV=local, MYSQL_ROOT_PASSWORD, TRAEFIK_PHPMYADMIN_USERS
make networks && make certs && make up
curl -k -I https://phpmyadmin.docker.test   # 401 attendu (basic-auth), pas 404
```
Puis résoudre `*.docker.test` vers la machine. Chaque application : `docker compose up -d` dans
son dossier, après ce socle.

### Nouveau serveur

```bash
git clone <url> ~/infra && cd ~/infra
cp .env.example .env && $EDITOR .env        # ENV=prod, TRAEFIK_DASHBOARD_INSECURE=false, TRAEFIK_BIND vide,
                                            # LETSENCRYPT_EMAIL, TRAEFIK_CERTRESOLVER=le, trois *_USERS, trois *_DOMAIN
make networks && make up
make ps && make logs                        # acme : « Certificates obtained » pour les trois domaines du socle
crontab -e  →  0 */6 * * * ~/infra/configuration/traefik2/rotate-logs.sh >> ~/infra/configuration/traefik2/logs/rotate.log 2>&1
```
Détail et vérifications : `RUNBOOK-deploy.md`.

### Mettre à jour un hôte après une PR mergée

```bash
cd ~/infra && make deploy
```
`deploy` lit le `CHANGELOG.md` à ta place : si `compose.yml` ou la config statique ont changé
entre les deux commits, il recrée le reverse proxy ; sinon il s'arrête après `check`, la config
dynamique ayant déjà été rechargée à chaud. **Avant** `deploy`, poser dans `.env` toute nouvelle
variable annoncée par le CHANGELOG : `check` refuserait sinon, c'est voulu.

### Changer la configuration Traefik

| Ce qui change | Commande | Interruption |
|---|---|---|
| Un middleware, un certificat local, une route fichier (`dynamic/<ENV>/`) | aucune : `git pull` ou édition suffit | aucune |
| Entrypoints, ACME, journal d'accès, niveau de log (`traefik.<ENV>.yaml`) | `make traefik-config` | 1 à 3 s sur tous les sites |
| Ports, volumes, variables du service `reverse-proxy` dans `compose.yml` | `make traefik-config` | idem |
| Labels d'un autre service du socle | `docker compose up -d <service>` | ce service seul |

### Ajouter un middleware partagé

1. Déclarer dans `dynamic/prod/main.yaml` **et** `dynamic/local/main.yaml` si les deux
   environnements en ont besoin (ils sont indépendants).
2. Référencer depuis les labels de l'application : `middlewares=<nom>@file`.
3. Vérifier qu'il est bien chargé avant de l'attacher : un routeur qui référence un middleware
   inconnu est **supprimé** (404), pas dégradé.

### Démarrer le second moteur sur un hôte

```bash
make up PROFILES=mariadb          # ou : docker compose --profile mariadb up -d mariadb
```
Sans le profil, `make up` ne touche pas MariaDB s'il tourne déjà ; `make down` l'arrête.
phpMyAdmin propose les deux moteurs en permanence ; l'entrée MariaDB échoue simplement si le
conteneur est absent.

### Renommer des bases vers la convention `<env>_<slug>`

```bash
./ops/sync-db-names.sh --list                       # inventaire
./ops/sync-db-names.sh monapp:prod_monapp           # dry-run
./ops/sync-db-names.sh --apply monapp:prod_monapp   # copie + droits ; l'ancienne reste
# mettre à jour DATABASE_URL de l'application, redéployer, vérifier, puis :
./ops/sync-db-names.sh --apply --drop-old monapp:prod_monapp
```

### Installer le contrôle hebdomadaire de restauration

Sur la machine d'exploitation (docker + ssh vers les serveurs) :

```bash
cd ~/infra/ops/backup-check
cp backup.env.example backup.env.<hote> && $EDITOR backup.env.<hote>
cp systemd/restore-check@.{service,timer} ~/.config/systemd/user/
loginctl enable-linger "$USER"; systemctl --user daemon-reload
systemctl --user enable --now restore-check@<hote>.timer
systemctl --user start restore-check@<hote>.service; journalctl --user -u restore-check@<hote> -n 40
```
Répéter la copie de `backup.env.<hote>` et l'`enable` pour chaque serveur.

### Rotation des journaux

Cron toutes les six heures sur chaque serveur (ci-dessus). Forcer : `MAXSIZE=0
./configuration/traefik2/rotate-logs.sh`. Lire : `zcat logs/access.log.1.gz | jq -r
'[.ClientHost, .RequestHost, .RequestPath, .DownstreamStatus] | @tsv'`.

### Arrêt complet et redémarrage

```bash
make down           # applications : 502 (proxy absent) et erreurs SQL pendant l'arrêt
make up             # le socle revient ; les applications se reconnectent d'elles-mêmes
```
`make down` ne supprime ni `datas/`, ni `letsencrypt/`, ni les réseaux externes.

### Revenir en arrière

```bash
git log --oneline -5
git checkout <commit-précédent> -- compose.yml configuration/   # ou git revert <commit>
make traefik-config
```
Les changements de config dynamique se défont en rééditant le fichier (rechargement à chaud).

### Avant d'ouvrir une PR

```bash
make test                   # bats
docker compose config -q    # avec un .env local complet
grep -rn 'secret\|password' --include='*.yaml' configuration/   # rien de réel dans les fichiers versionnés
```
Puis renseigner `CHANGELOG.md` : ce qui change et **si une action serveur est requise**
(nouvelle variable `.env`, `make traefik-config`, cron).
