# Architecture

## 1. Un hôte, un socle, N applications

```
Internet / VPN ──► :80 ─► redirection 443
                    :443 ─► infra_traefik ──► réseau `traefik` ──► nginx/app des projets
                                                                      │
                                                 réseau `databases` ──┼── infra_mysql_8_0
                                                                      │   infra_mariadb_11_3 (profil)
                                                                      │   infra_phpmyadmin
                                                 réseau `mailer`   ───┴── infra_mailer (SMTP :1025)
```

Le socle est **durable** : il démarre une fois, survit aux déploiements des applications, et
porte les seuls `container_name` fixes de l'hôte. Les applications sont **éphémères** : elles
se recréent à chaque déploiement sans toucher au socle.

Trois réseaux Docker **externes**, créés une fois par `make networks` et jamais supprimés par
`make down` :

| Réseau | Qui le rejoint | Pourquoi séparé |
|---|---|---|
| `traefik` | Traefik, et les seuls services HTTP à publier | Ce que Traefik voit, il peut le router : ne pas y mettre une base |
| `databases` | Les deux moteurs, phpMyAdmin, les conteneurs applicatifs qui ont besoin de SQL | Isoler SQL du HTTP |
| `mailer` | Mailpit, les conteneurs qui envoient du mail | Idem |

## 2. Traefik : statique, dynamique, labels

Trois sources de configuration, trois cycles de vie :

| Source | Fichier | Rechargement | Contient |
|---|---|---|---|
| **Statique** | `configuration/traefik2/config/traefik.<ENV>.yaml` | **recréation du conteneur** (`make traefik-config`) | entrypoints, providers, ACME, journal d'accès, niveau de log |
| **Dynamique fichier** | `configuration/traefik2/config/dynamic/<ENV>/*.yaml` | **à chaud**, dès l'écriture | certificats locaux, middlewares partagés, routes vers des services hors Docker |
| **Dynamique Docker** | labels des conteneurs | à chaud, à chaque événement Docker | routeurs et services des applications |

**Pourquoi un dossier et pas un fichier pour la config dynamique.** Un bind mount de fichier
est résolu à la création du conteneur sur un inode précis. `git pull` écrit un fichier
temporaire puis le renomme : nouvel inode, et le conteneur continue de lire l'ancien contenu.
Les middlewares « disparaissent », tous les routeurs qui les référencent sont supprimés, tous
les sites répondent 404 alors que le fichier sur disque est correct. Avec un dossier monté,
Traefik observe le répertoire et recharge réellement. `bin/infra-check` vérifie que le dossier
existe et n'est pas vide.

**Pourquoi les middlewares partagés ne sont attachés à aucun entrypoint.** Un même hôte héberge
des sites aux besoins différents. Un `X-Frame-Options` global casserait une application qui
affiche ses propres PDF ; une `Permissions-Policy: geolocation=()` globale casserait une carte.
Chaque application s'attache explicitement (`middlewares=security-headers@file`) : l'opt-in est
la règle, et la panne d'un middleware ne touche que ceux qui l'ont demandé.

**Pourquoi `exposedbydefault: false`.** Un conteneur n'est publié que s'il porte
`traefik.enable=true`. Un conteneur de build, un worker, une base ne sortent jamais par accident.

## 3. TLS

| Environnement | Mécanisme | Où |
|---|---|---|
| `local` | Certificat **mkcert** couvrant `docker.test`, `*.docker.test` (et `docker.localhost`), servi par le provider fichier (`dynamic/local/main.yaml`). Les routeurs posent `tls=true` **sans** resolver (`TRAEFIK_CERTRESOLVER=`). | `configuration/traefik2/certs/` |
| `prod` | **Let's Encrypt**, résolveur `le`, challenge HTTP sur l'entrypoint `web`. Les routeurs posent `tls.certresolver=le`. | `letsencrypt/acme.json` (600, propriété root) |

Conséquence : en local, le port 80 doit rester **non publié sur Internet** (sinon le challenge
ACME n'a pas de sens et le tableau de bord est ouvert) ; en prod, le port 80 doit rester
**joignable** depuis Internet pour le challenge, même si tout est redirigé vers 443.

## 4. Les moteurs de base de données

- **MySQL 8.0** : le moteur par défaut, une instance par hôte, toutes les applications.
- **MariaDB 11.3** : second moteur, sous **profil Compose** (`make up PROFILES=mariadb`). Il
  existe pour les applications dont la production tourne en MariaDB : Doctrine et consorts
  génèrent du SQL différent selon le moteur et sa version (`serverVersion`), les collations
  diffèrent, le type `JSON` n'est pas le même. Tester sur le mauvais moteur masque des écarts.
  Règle : MariaDB **n'est pas** « la deuxième base de tout le monde » ; une application choisit
  un moteur et s'y tient.
- Même mot de passe root pour les deux (`MYSQL_ROOT_PASSWORD`). Les applications utilisent des
  comptes dédiés par base, créés à la main ou par leur propre script d'initialisation.
- Données en bind mount sous `datas/` : la sauvegarde physique du dossier n'est **pas** une
  sauvegarde cohérente ; dumper (`--single-transaction`) ou arrêter le moteur.

## 5. Conventions de nommage

| Objet | Convention | Exemple |
|---|---|---|
| Domaine local | `<projet>.docker.test` | `monapp.docker.test` |
| Domaine prod | le vrai domaine ; alias `www.` redirigé vers l'apex | `monapp.example.org` |
| Base de données | `<env>_<slug>` sur un serveur mixte dev/prod ; `<slug>` seul en local | `prod_monapp`, `dev_monapp` |
| Conteneur applicatif | pas de `container_name` : laisser Compose nommer `<projet>-<service>-1` | `monapp-php-1` |
| Conteneur du socle | `infra_<service>` | `infra_traefik` |
| Routeur Traefik | `${COMPOSE_PROJECT_NAME}` et suffixes `-alias`, `-ws`… | `monapp`, `monapp-alias` |
| Middleware partagé | déclaré dans `dynamic/prod/main.yaml`, référencé `<nom>@file` | `security-headers@file` |

`ENV` vaut `local` ou `prod` et désigne **le type d'hôte**, pas l'environnement de l'application :
un serveur `prod` héberge souvent aussi des stacks de recette (`dev.monapp.example.org`,
base `dev_monapp`). La séparation dev/prod se fait au niveau des applications (préfixes de base,
sous-domaines), pas au niveau du socle.

## 6. Ce que le socle ne fait pas

- Il ne **produit pas de sauvegardes** : `ops/backup-check` vérifie que des bases sont
  restaurables, il ne conserve rien. La production des sauvegardes (chiffrement, rotation,
  hors site) est un outillage séparé, à installer sur chaque serveur.
- Il ne porte **aucune logique applicative** ni aucun outil de développement.
- Il ne gère **pas le DNS** ni le pare-feu de l'hôte.
