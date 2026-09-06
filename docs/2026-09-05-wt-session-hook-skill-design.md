# Hook SessionStart + skill `/worktree-env` (design)

Date : 2026-09-05 · Statut : design validé (en attente de relecture) · Portée : **sous-projet 2/3** · Dépend de : sous-projet 1 (moteur `wt`).

## 1. Contexte & objectif

Le moteur `wt` (SP1) crée/détruit des envs de worktree isolés. SP2 le **câble dans le cycle de vie Claude Code** pour que l'usage soit sans friction depuis mobile/PC :
- **détecter**, à l'ouverture d'une session dans un repo d'app, si un travail est en cours, et **proposer** un worktree propre (jamais de création lourde automatique) ;
- **exécuter** la création/gestion via un skill conversationnel qui pilote `wt`.

## 2. Périmètre

**Dans le périmètre :**
- Un **hook `SessionStart`** (bash) : lecture seule, rapide, fail-safe ; détecte + suggère.
- Un **skill `/worktree-env`** (user-level, `~/.claude/skills/worktree-env/`) : pilote `wt create|list|open|destroy` en conversation.
- Enregistrement du hook dans `~/.claude/settings.json`.

**Hors périmètre :**
- Toute auto-création d'env par le hook (interdit — cf. §6).
- Le dashboard (SP3).
- Support d'apps hors des 5 Symfony connues de `wt` (v2 pour PrestaShop).

## 3. Détection (le hook)

- **Portée** : le hook n'agit que si le `cwd` est **sous l'un des 5 repos d'`apps.conf`** (résolution : chemin `cwd` préfixé par un `repo_path` connu). Sinon : sortie silencieuse (exit 0, aucun contexte).
- **« Travail en cours »** = **arbre sale** (`git status --porcelain` non vide) **OU** branche courante **≠ base** de l'app (develop ; hotfix→main).
- **Registre** : le hook interroge aussi `wt list --json` pour lister les envs actifs de cet app.

## 4. Contrat du hook (SessionStart)

- Script `Infra/bin/wt-session-hook`, invoqué par le hook `SessionStart` déclaré dans `~/.claude/settings.json`.
- Appelle `wt` par **chemin absolu** (`Infra/bin/wt`) — SP2 suppose le moteur installé/accessible.
- **Sortie** : émet du contexte via le mécanisme `additionalContext` de SessionStart (schéma JSON exact à confirmer dans le plan — `hookSpecificOutput.additionalContext`), ou stdout selon le contrat de la version installée.
- **Fail-safe absolu** : toute erreur (repo inconnu, git absent, `wt` indisponible, timeout) → **exit 0 sans casser la session**. Rapide (< ~1 s), lecture seule.

## 5. Message de suggestion (format)

Concis, actionnable, ex :
```
wt · <app> : travail en cours (branche <branche>, <N> fichier(s) modifié(s)).
Pour isoler un nouveau ticket sans perturber ce travail, demande un worktree :
  « nouveau worktree <TICKET> »  (→ wt create)
Envs actifs : <app>-<slug> → https://<app>-<slug>.docker.test  [· …]
```
Si repo propre sur sa base et aucun env actif : aucun message.

## 6. Exécution (le skill `/worktree-env`)

Déclencheurs : « on démarre GEL-123 », « nouveau worktree … », « /worktree-env … », « liste mes worktrees », « supprime le worktree … ».
- **create** : mappe `cwd` → app (via `apps.conf`), déduit feature/hotfix (défaut feature ; hotfix si le ticket/le contexte l'indique), `slug` depuis le ticket → `wt create <app> <slug> --feature|--hotfix --ticket KEY` ; rend l'URL + le chemin.
- **list** : `wt list` (tableau).
- **open** : `wt open <app> <slug>` → chemin (pour cd/nouvelle session).
- **destroy** : `wt destroy <app> <slug>` **avec confirmation explicite** avant toute destruction (rappel : opération destructive).
- Toujours proposer un `--dry-run` d'abord pour create/destroy si le moindre doute.

Le hook ne fait que **suggérer** ; toute action lourde/destructive passe par le skill, donc par une intention explicite de l'utilisateur.

## 7. Dépendances

Moteur `wt` (SP1) présent et fonctionnel (`Infra/bin/wt`, `etc/wt/apps.conf`) ; `git`, `jq`. Claude Code avec support des hooks `SessionStart`.

## 8. Tests

- **Hook** (`Infra/bin/wt-session-hook`) : suite `bats` — cwd sous un repo connu vs inconnu ; arbre sale vs propre ; branche ≠ base ; présence d'envs actifs (registre factice) → on assert le contexte émis (ou l'absence). `wt`/git mockés via un `PATH` de test ou des fixtures, aucune vraie action.
- **Skill** : validé par un `--dry-run` des appels `wt` (le skill est de l'instruction ; pas de test unitaire, mais un scénario documenté).

## 9. Décisions ouvertes / suite

- Confirmer dans le plan le **schéma exact** de sortie `SessionStart` de la version Claude Code installée (`additionalContext`), et la forme exacte du bloc `hooks` dans `settings.json` (utiliser le skill `update-config` si besoin).
- Nom du skill : `/worktree-env`. Emplacement : `~/.claude/skills/worktree-env/`.
- **SP3** : dashboard (liste, aller/supprimer, métriques RAM/CPU/disque).
