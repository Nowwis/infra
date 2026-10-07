# Sécurité

## 1. Ce qui est exposé, et derrière quoi

| Service | `ENV=local` | `ENV=prod` |
|---|---|---|
| Tableau de bord Traefik | ouvert (`insecure=true`), **écoute restreinte obligatoire** (`TRAEFIK_BIND`) | basic-auth `auth`, `insecure=false` |
| phpMyAdmin | basic-auth dédié (**obligatoire**, sinon 404) | idem |
| Mailpit | libre ou `mailpit-auth` selon `.env` | basic-auth `mailpit-auth` |
| MySQL / MariaDB | réseau `databases` uniquement, aucun port hôte | idem |
| SMTP Mailpit | réseau `mailer` uniquement | idem |
| Sites applicatifs | selon leurs labels | selon leurs labels |

Règles :

- **Trois secrets basic-auth différents.** phpMyAdmin ouvre toutes les bases de l'hôte ; il ne
  partage pas le mot de passe d'un écran de supervision ni d'un capteur de mails.
- **Échec fermé.** Une variable `*_USERS` vide rend le middleware invalide et le routeur est
  supprimé : l'outil répond 404, jamais « accès libre ». `make check` refuse de déployer dans
  ce cas, pour que le 404 ne surprenne pas.
- **Un hôte `local` n'écoute jamais sur Internet.** `TRAEFIK_BIND=127.0.0.1:` ou l'IP d'une
  interface privée (VPN). Ne jamais placer un tunnel public (ngrok, Funnel, port-forward) devant
  Traefik : il expose **tous** les vhosts via l'en-tête `Host`, tableau de bord et phpMyAdmin
  compris.
- **Un hôte `prod` écoute sur tout** (`TRAEFIK_BIND` vide) : le pare-feu de l'hôte n'ouvre que
  22, 80, 443. Rien d'autre n'est publié par le socle.

## 2. Où vivent les secrets

| Secret | Fichier | Versionné |
|---|---|---|
| Mot de passe root SQL, hash basic-auth, e-mail ACME | `.env` | non (`.gitignore`) |
| Certificat et clé mkcert | `configuration/traefik2/certs/` | non |
| Comptes et clés Let's Encrypt | `letsencrypt/acme.json` (root, 600) | non |
| Config du contrôle de restauration (clé d'API mail, hôtes, bases) | `ops/backup-check/backup.env.<hote>` | non |
| Historique de volumétrie | `ops/backup-check/.restore-history.csv` | non |

Ce que le dépôt versionne ne contient **aucun** secret, **aucun** nom d'hôte réel, **aucun**
nom de projet : il peut être public. L'inventaire réel (hôtes, bases, destinataires) vit dans un
dépôt privé ou un gestionnaire de secrets, selon le gabarit `HOSTS.md`.

## 3. Hash basic-auth

- Recommandé : **bcrypt** (`htpasswd -nbB`), généré sans rien installer :
  `docker run --rm httpd:alpine htpasswd -nbB admin 'motdepasse' | tr -d '\n' | sed 's/\$/$$/g'`.
- Dans un `.env` lu par Compose, chaque `$` doit être écrit `$$`, sinon le hash est tronqué en
  silence et plus aucun mot de passe ne fonctionne. `make check` détecte un `$` nu.
- `{SHA}` (`htpasswd -ns`) évite l'échappement mais c'est du SHA-1 non salé : acceptable pour
  un écran de supervision, pas pour phpMyAdmin.

## 4. En-têtes de sécurité

Déclarés dans `dynamic/prod/main.yaml`, **opt-in par application** (`security-headers@file`).
HSTS démarre à 300 s : une erreur est irréversible côté navigateur pendant tout `max-age`.
Passer à un an, puis `includeSubDomains`, puis `preload`, seulement après inventaire de **tous**
les sous-domaines (chacun doit être joignable en HTTPS seul). Pas de Content-Security-Policy au
niveau du proxy : elle demande un nonce par requête, donc elle relève de l'application.

## 5. Journal d'accès

Format JSON, champs `Referer`, `User-Agent`, `Cf-Connecting-Ip`, `X-Forwarded-For` conservés :
le journal contient des **données personnelles** (adresses IP). Rotation toutes les 6 h,
7 archives : environ deux jours de rétention à fort trafic, à documenter dans le registre de
traitements si la réglementation l'exige. Le dossier `logs/` n'est pas versionné et appartient à
root (écrit par le conteneur).

## 6. Surface Docker

Traefik monte `/var/run/docker.sock` en lecture seule : un Traefik compromis lit l'état de tous
les conteneurs de l'hôte. C'est le prix du provider Docker ; l'alternative (proxy de socket
filtrant) n'est pas mise en place ici. Le socle n'exécute rien en tant que root hors des
conteneurs.

## 7. Signaler

Une faille dans la configuration du socle : ouvrir une issue privée ou écrire au mainteneur
indiqué dans le dépôt, sans publier le détail avant correction.
