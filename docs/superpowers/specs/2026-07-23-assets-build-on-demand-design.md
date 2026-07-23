# Compilation des assets à la demande — suppression des conteneurs Node permanents

**Date** : 2026-07-23
**Statut** : validé, à implémenter
**Portée** : 9 projets sous `~/Project/`

## Problème

Neuf projets déclarent un service `nodejs` permanent dans leur `.docker/docker-compose.yml`,
avec ce pattern :

```yaml
command: bash -c "yarn install && yarn encore dev --watch && tail -f /dev/null"
```

`yarn encore dev --watch` est bloquant : le `tail -f /dev/null` ne devrait jamais s'exécuter.
Quand le watcher meurt, `tail` prend le relais et le conteneur reste `Up`. `docker ps`
affiche alors `Up 7 weeks` pour un conteneur qui ne compile plus rien.

Constat au 2026-07-23 : **6 des 9 conteneurs Node exécutaient `tail -f /dev/null`**.

| Conteneur | RAM | Process réel |
|---|---|---|
| `bifacto-app-node-1` | 710 Mo | serveur Vite |
| `myprojekt-app-nodejs-1` | 491 Mo | `yarn watch` |
| `bifacto-doc-nodejs-1` | 230 Mo | `webpack --watch` |
| `asteria-nodejs-1` | 24 Mo | `tail -f /dev/null` |
| `consotrust-nodejs-1` | 20 Mo | `tail -f /dev/null` |
| `direkto-nodejs-1` | 20 Mo | `tail -f /dev/null` |
| `uspa-nodejs-1` | 19 Mo | `tail -f /dev/null` |
| `parisrental-nodejs-1` | 16 Mo | `tail -f /dev/null` |
| `lagestionenligne-nodejs-1` | 15 Mo | `tail -f /dev/null` |

Le coût mémoire des zombies est négligeable (~115 Mo). Le vrai défaut est que **la panne est
silencieuse** : rien ne distingue un watcher vivant d'un watcher mort.

## Contrainte déterminante

L'édition du code est faite quasi exclusivement par un agent, pas à la main. Le mode *watch*
sert une boucle édition-sauvegarde-rafraîchissement humaine ; il n'a pas de raison d'être ici.
Un agent sait quand il a fini de modifier des assets et peut déclencher le build explicitement.

Corollaire retenu dès la conception : **le dispositif ne doit pas reposer sur la mémoire de
l'agent**. D'où le filet `pre-commit` décrit plus bas.

## Segmentation

L'audit interdit d'appliquer le même changement partout.

### Catégorie 1 — rien à compiler (2 projets)

`uspa`, `direkto` : aucun `package.json`, aucun lockfile, aucune config webpack.
Le conteneur lance `yarn install` dans le vide, échoue, tombe sur `tail`.

**Action** : supprimer purement le service `nodejs` du compose. Il n'a jamais rien eu à faire.
Supprimer également la cible `yarn:` de leur `Makefile`, qui référencerait un service inexistant.

### Catégorie 2 — build réel, watcher mort (4 projets)

`parisrental`, `asteria`, `consotrust`, `lagestionenligne`.

**Action** : passage à la demande (voir ci-dessous).

`asteria.immo` est un cas particulier : son unique script est
`sass assets/scss/main.scss assets/css/main.css --watch`. Il n'existe aucun script de build
one-shot ; il faudra en ajouter un (le même sans `--watch`).

### Catégorie 3 — watcher fonctionnel (3 projets)

`myprojekt-app`, `bifacto-doc`, `bifacto-app`.

**Action** : passage à la demande également. Ils fonctionnent, mais n'ont pas plus besoin
d'un watcher permanent que les autres.

## Conception

### Service éphémère

Dans `.docker/docker-compose.yml` des 7 projets des catégories 2 et 3 :

```yaml
nodejs:
    profiles: ["tools"]     # ne démarre plus avec `make up`
```

`docker compose run` active automatiquement le profil du service nommé : le service reste
utilisable à la demande sans jamais démarrer avec la stack.

Le `command:` bloquant est supprimé — la commande est fournie par `run`.

### Points d'entrée Makefile

Les 8 projets à Makefile partagent déjà le vocabulaire
`build up upbuild upinfo down exec yarn install migrate clean-cache deploy`.

Les cibles ci-dessous s'appliquent aux **6 projets à Makefile des catégories 2 et 3**
(`parisrental`, `asteria`, `consotrust`, `lagestionenligne`, `myprojekt-app`, `bifacto-doc`) —
`bifacto-app` n'a pas de Makefile, `uspa` et `direkto` perdent leur cible `yarn`.
On conserve la sémantique de `yarn` (shell interactif) en changeant seulement son
implémentation, et on ajoute deux cibles :

```make
yarn:                          # sémantique inchangée, éphémère en dessous
	$(DOCKER_COMPOSE) run --rm nodejs bash
assets:                        # build à la demande
	$(DOCKER_COMPOSE) run --rm nodejs yarn dev
watch:                         # cas rare : un humain veut le watch
	$(DOCKER_COMPOSE) run --rm nodejs yarn watch
```

Le nom du script varie : `dev` / `watch` pour les 5 projets Encore, `sass` pour `asteria.immo`
(script one-shot à créer). La cible reste nommée `assets` partout — c'est le point d'entrée
uniforme qui compte, pas la commande sous-jacente.

`node_modules` persiste entre deux exécutions : il est sur le bind-mount
`${APP_FOLDER}:/var/www` déjà en place. Aucune installation Node sur l'hôte ;
la version de Node reste épinglée par projet dans le compose.

### Filet anti-oubli

Les assets compilés sont gitignorés partout (`/public/build/`, `/build/`). Le hook n'a donc
**rien à re-stager** : son rôle est une validation — *est-ce que ça compile encore ?*

Hook `pre-commit`, installé par `make init-dev` (cible déjà présente sur les 8 projets) :

1. Si aucun fichier indexé ne touche les sources d'assets
   (`assets/`, `package.json`, lockfile, `webpack.config.js`, `vite.config.*`) → sortie 0.
2. Sinon, exécuter `make assets`.
3. Échec du build → commit refusé, code de sortie non nul.

En complément, une ligne dans le `CLAUDE.md` de chaque repo (conforme à la convention
Paperclip existante) indiquant de lancer `make assets` après modification des assets.
Le `CLAUDE.md` informe l'agent ; le hook le contraint. Les deux sont retenus.

## Hors périmètre

**`bifacto-app`** : Vite + npm, sans Makefile. Même principe (`profiles` + `run --rm`),
mais points d'entrée à définir séparément. Scripts disponibles : `dev`, `build`
(`tsc -b && vite build`), `lint`, `preview`, `test`.

**Assets de production potentiellement périmés.** `deploy: install migrate clean-cache` ne
compile aucun asset, et aucune occurrence de `encore production` / `yarn build` / `vite build`
n'a été trouvée dans les `Makefile`, `tools/` ni `.github/` de `uspa` et `direkto`.
Pour les 4 projets de catégorie 2, dont le watcher est mort depuis ~7 semaines, cela pose une
question que cette spec ne tranche pas : **comment la production obtient-elle ses assets, et
sont-ils à jour ?** Investigation distincte, avec un risque réel derrière.

**Image `nikolaik/python-nodejs:latest`** : utilisée par 7 projets sur 9, épinglée sur
`latest` — le build peut changer sans préavis. Épinglage recommandé, non traité ici.

## Critères de réussite

- `docker ps` ne montre plus aucun conteneur `nodejs` au repos.
- `make assets` produit un build correct sur chacun des 7 projets concernés.
- Un commit touchant les sources d'assets avec un build cassé est refusé.
- `make up` ne démarre plus de service `nodejs`.
- `uspa` et `direkto` n'ont plus de service `nodejs` déclaré.
