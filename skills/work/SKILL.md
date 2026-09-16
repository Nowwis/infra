---
name: work
description: Workflow gitflow à checkout unique — démarrer un ticket (« on démarre GEL-123 »), ouvrir la PR (« ouvre la PR »), nettoyer après merge (« c'est mergé »), reprendre ou mettre de côté un ticket, état des projets. À invoquer AVANT toute écriture de code dans un projet géré.
---

# work — un ticket en écriture à la fois par projet

Un seul checkout et une seule stack par projet. Une seule session Claude écrit dans un
projet à la fois ; les autres lisent, analysent (prod en lecture comprise) ou travaillent
sur un autre projet. Le CLI est `/home/webadmin/Project/Infra/bin/work`, lancé depuis le
dossier du projet. Une garde (hook PreToolUse) bloque toute écriture hors ticket démarré.

## Workflow

1. **Démarrer** — « on démarre GEL-123 », « attaque le ticket 456 »
   - Si `.claude/gitflow.json` existe dans le repo et décrit Jira : lire le ticket
     (serveur MCP `jira.mcpServer`, `cloudId`), afficher clé, résumé, type.
   - Proposer feature ou hotfix (Bug/Incident → hotfix) et un slug court en kebab-case
     tiré du résumé, puis **faire confirmer** par Simon.
   - `work start <KEY> [--hotfix] [--slug <slug>]` : pull de main et develop, branche
     `feature/<KEY>-<slug>` depuis develop ou `hotfix/<KEY>-<slug>` depuis main.
2. **Travailler** sur la branche : commits réguliers, messages en anglais.
3. **Ouvrir la PR** — « ouvre la PR »
   - Rédiger titre et description (anglais, **aucune mention de Claude, d'une IA ni de
     co-auteur**), les montrer à Simon et **attendre sa validation** : push et PR sont des
     actions sortantes.
   - Écrire la description dans un fichier temporaire, puis
     `work pr --title "<titre>" --body-file <fichier>`. Le projet revient sur main à jour.
4. Simon merge la PR.
5. **« c'est mergé »** (facultatif) — `work merged [KEY]` : vérifie le merge sur GitHub,
   met main et develop à jour, supprime la branche locale. Sur GitLab (consotrust), le merge
   n'est pas vérifiable : demander confirmation à Simon puis `work merged <KEY> --confirmed`.
   Sans cette étape, le ménage est fait au `work start` suivant.

## Autres commandes

- `work status` / `work status --all` — état du projet ou de tous (« état des projets »).
- `work resume <KEY>` — reprendre une branche en attente (retours de relecture, ticket mis de côté).
  Après les corrections : `work pr` (la PR existante est réutilisée).
- `work park` — hotfix urgent pendant une feature : commit `wip` + push (**validation de
  Simon avant le push**), retour sur main. Jamais de `git stash`.
- `work adopt <KEY>` — enregistrer une branche déjà en cours comme ticket (migration).
- `work takeover` — reprendre un ticket tenu par une autre session, **uniquement si Simon le demande**.

## Quand la garde bloque

- « aucun ticket démarré » : ne pas contourner ; proposer `work start` (ou demander à Simon
  quel ticket) avant d'écrire.
- « tenue par une autre session » : rester en lecture seule sur ce projet et le dire à Simon.
- « session terminée » : proposer `work takeover` à Simon, sans l'exécuter de soi-même.
- Ne jamais désactiver la garde (`WORK_GUARD=off`) sans demande explicite de Simon.
