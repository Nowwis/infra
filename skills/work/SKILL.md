---
name: work
description: Workflow gitflow à checkout unique. À invoquer AVANT toute écriture de code dans un projet géré — pas seulement pour un ticket nommé, mais dès qu'on démarre une nouvelle fonctionnalité, qu'on corrige un bug, qu'on modifie du code existant, qu'on ouvre la PR (« ouvre la PR »), qu'on nettoie après merge (« c'est mergé »), qu'on reprend, met de côté ou abandonne un travail, ou qu'on demande l'état des projets.
---

# work — un ticket en écriture à la fois par projet

Un seul checkout et une seule stack par projet. Une seule session Claude écrit dans un
projet à la fois ; les autres lisent, analysent (prod en lecture comprise) ou travaillent
sur un autre projet. Le CLI est `/home/webadmin/Project/Infra/bin/work`, lancé depuis le
dossier du projet. Une garde (hook PreToolUse) bloque toute écriture hors ticket démarré.

## Quand l'invoquer

Avant **toute** écriture dans un projet géré, quelle que soit la formulation de Simon :

- un ticket nommé : « on démarre GEL-123 », « attaque le ticket 456 » ;
- une nouvelle fonctionnalité : « ajoute un filtre par statut », « il faudrait pouvoir exporter en CSV » ;
- un bug : « ça plante quand on valide le formulaire », « corrige l'erreur 500 sur la facture » ;
- une modification de code, de configuration, de tests ou de dépendances, même petite ;
- les étapes suivantes : ouvrir la PR, « c'est mergé », reprendre, mettre de côté, abandonner, état des projets.

Sans clé de ticket fournie, en proposer une courte et parlante (`EXPORT-CSV`, `FIX-500-FACTURE`)
et la faire confirmer. Dans le doute, invoquer **avant** d'écrire : la garde refusera de toute
façon, et un refus en cours de route coûte plus cher qu'un ticket ouvert pour rien
(`work abort` le referme proprement).

## Workflow

1. **Démarrer**
   - Si `.claude/gitflow.json` existe dans le repo et décrit Jira : lire le ticket
     (serveur MCP `jira.mcpServer`, `cloudId`), afficher clé, résumé, type.
   - Proposer feature ou hotfix (bug ou incident → hotfix) et un slug court en kebab-case,
     puis **faire confirmer** par Simon.
   - `work start <KEY> [--hotfix] [--slug <slug>]` : pull de main et develop, branche
     `feature/<KEY>-<slug>` depuis develop ou `hotfix/<KEY>-<slug>` depuis main.
   - Si le projet a déjà des modifications en cours qu'il faut emporter sur la nouvelle branche :
     `work start <KEY> --keep-changes`. Sans cette option, un fichier suivi modifié bloque le
     démarrage (les fichiers jamais ajoutés, eux, n'ont jamais bloqué).
2. **Travailler** sur la branche : commits réguliers, messages en anglais.
3. **Ouvrir la PR** — « ouvre la PR »
   - Rédiger titre et description (anglais, **aucune mention de Claude, d'une IA ni de
     co-auteur**), les montrer à Simon et **attendre sa validation** : push et PR sont des
     actions sortantes.
   - Écrire la description dans un fichier temporaire, puis
     `work pr --title "<titre>" --body-file <fichier>`. Le projet revient sur main à jour.
4. Simon merge la PR.
5. **« c'est mergé »** (facultatif) — `work merged [KEY]` : vérifie le merge sur GitHub,
   met main et develop à jour, supprime la branche locale. Sans cette étape, le ménage est
   fait au `work start` suivant.

## Autres commandes

- `work status` / `work status --all` — état du projet ou de tous (« état des projets »).
- `work sync [--tidy]` — met `main` et `develop` à jour sans démarrer de ticket (« mets à jour les
  bases »). Avec `--tidy`, si la branche courante n'est pas une base et que sa PR est mergée, le
  projet revient sur `main` et la branche locale est supprimée. Ne touche jamais à une branche qui
  porte un ticket actif ni à un fichier suivi modifié.
- `work resume <KEY>` — reprendre une branche en attente (retours de relecture, ticket mis de côté).
  Après les corrections : `work pr` (la PR existante est réutilisée).
- `work park` — hotfix urgent pendant une feature : commit `wip` + push (**validation de
  Simon avant le push**), retour sur main. Jamais de `git stash`.
- `work abort [--force]` — abandonner le ticket en cours : retour sur main, suppression de la
  branche **locale** (jamais la distante), projet libéré. Refuse s'il y a des commits ou des
  fichiers suivis modifiés, et renvoie alors vers `work park` ; `--force` passe outre en
  annonçant ce qui est perdu. **Demander confirmation à Simon avant un `--force`.**
- `work adopt <KEY>` — enregistrer une branche déjà en cours comme ticket (migration).
- `work takeover` — reprendre un ticket tenu par une autre session, **uniquement si Simon le demande**.

## GitLab (consotrust)

Le flux PR n'est pas géré pour l'instant : `work start`, `work sync`, `work status`, `work abort`
fonctionnent normalement, mais la merge request se crée à la main (l'URL est affichée par
`work pr`) et `work merged` n'est pas utilisé sur ce projet.

## Quand la garde bloque

- « aucun ticket démarré » : ne pas contourner ; proposer `work start` (ou demander à Simon
  quel ticket) avant d'écrire.
- « tenue par une autre session » : rester en lecture seule sur ce projet et le dire à Simon.
- « session terminée » : proposer `work takeover` à Simon, sans l'exécuter de soi-même.
- Ne jamais désactiver la garde (`WORK_GUARD=off`) sans demande explicite de Simon.
