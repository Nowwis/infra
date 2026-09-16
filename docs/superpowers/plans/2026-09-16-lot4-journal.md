# Lot 4 — Journal d'activité Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans.

**Goal:** Savoir, depuis la console, ce que chaque session Claude est en train de faire — elle exécute, elle attend une réponse, elle est au repos, elle a été bloquée par la garde — sans jamais enregistrer le texte des prompts.

**Architecture:** Un hook unique `bin/console-hook`, branché sur 8 événements Claude Code, ajoute une ligne JSON à `~/.local/state/console/events-<date>.jsonl`. Le collecteur en déduit un statut par session (section `sessions`) et un flux d'activité (nouvelle section `activity`). La console les affiche.

**Spec:** `docs/2026-09-15-work-console-design.md` §6.

## Contraintes mesurées
- La garde coûte déjà **41 ms** par appel d'outil (démarrage de python3 + shlex). Le hook de journal doit rester **sous 15 ms** : bash + un seul `jq`, jamais python.
- Écriture par un seul `>>` d'une ligne < 4 Ko (atomique sous PIPE_BUF), jamais de lecture-modification-écriture.
- Toujours `exit 0`, aucune sortie sur stdout : un hook de journal ne doit jamais bloquer un outil.

## Tâches
1. **`bin/console-hook` + tests** — événements `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SubagentStop`, `SessionEnd`. Ligne : `ts, event, session, cwd, project, tool, tool_use_id, summary, result`. `summary` : commande Bash tronquée à 300 car., chemin pour Edit/Write, message pour Notification, **rien pour les prompts**. Masquage : `password|token|secret|api_key=…`, `://user:pass@`, `Bearer …`, chaînes hex/base64 > 32 car. Tests : format, masquage, troncature, absence de prompt, exit 0 sur entrée invalide, durée < 15 ms.
2. **Garde : journaliser les blocages** — `work-guard` écrit `event: "guard.block"` avec le motif, via la même fonction d'écriture. Tests : un blocage produit une ligne, un passage n'en produit pas.
3. **Section `activity` du collecteur** (cadence 5 s) — les 200 derniers événements, projet et session résolus ; rétention : suppression des fichiers de plus de 7 jours.
4. **Statut par session** — enrichir `sessions` : `PreToolUse` sans `PostToolUse` apparié → « exécute <outil> depuis N s » ; `Notification` → « attend une réponse » ; `UserPromptSubmit`/`PostToolUse` → « travaille » ; `Stop` → « au repos depuis N » ; pid mort → absente. Appariement par `tool_use_id` si le champ existe, sinon dernier `PreToolUse` de la session. Nouveau diagnostic : session au repos > 2 h avec > 300 Mo.
5. **Console** — badge d'état sur chaque session, panneau « Activité » filtrable par projet, blocages de la garde mis en évidence.
6. **Installation** — `bin/work-hook-install` déclare aussi `console-hook` sur les 8 événements ; `--uninstall` le retire. Tests sur un `settings.json` temporaire.
7. **Doc + PR** — `docs/console-README.md` (journal, rétention, ce qui n'est jamais enregistré), suite verte, PR.

## Point ouvert à vérifier dès la tâche 1
Le champ `tool_use_id` est-il présent dans les payloads `PreToolUse`/`PostToolUse` de la version installée ? Le hook journalise tout ce qu'il reçoit : un `jq` sur les premières lignes réelles répondra, et l'appariement se replie sur « dernier PreToolUse » si le champ manque.
