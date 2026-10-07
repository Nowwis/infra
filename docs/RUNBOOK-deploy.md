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
| Image (nouvelle version cassée) | épingler l'ancienne version dans `compose.yml`, `docker compose up -d <service>` |
| Tout | `git checkout <tag-ou-commit-connu> && make traefik-config && docker compose up -d` |

Les données (`datas/`, `letsencrypt/`) ne sont jamais touchées par ces opérations.

## 5. Ce qui ne doit jamais être fait sur un hôte

- Éditer `compose.yml` ou `configuration/` à la main (voir §3).
- Lancer `docker compose down -v` : le `-v` détruit les volumes nommés ; le socle n'en a pas,
  mais l'habitude est mauvaise.
- Supprimer `letsencrypt/acme.json` sans raison : Let's Encrypt limite les émissions par
  domaine et par semaine.
- Mettre `TRAEFIK_PHPMYADMIN_USERS` vide « pour tester » : phpMyAdmin passe en 404, pas en
  accès libre, c'est voulu ; mais on oublie ensuite pourquoi il ne répond plus.
