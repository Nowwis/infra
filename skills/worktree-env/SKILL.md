---
name: worktree-env
description: Manage worktrees — nouveau worktree, on démarre <TICKET>, liste mes worktrees, supprime le worktree
---

# Worktree Environment Skill

This skill manages isolated Git worktrees for feature and hotfix branches, mapped to running environments via the `wt` engine.

## Identify the current app

Before any operation, resolve the current working directory to an application name by matching its prefix against `etc/wt/apps.conf`.

- Read `etc/wt/apps.conf` (format: `app|repo|type|base|compose|install`)
- Extract the repo prefix for each app
- Match the current directory to find the app name
- If no match, tell the user "No managed app found for this directory" and stop

## Create a new worktree

**Triggers:** "create", "nouveau worktree", "start", "on démarre"

1. Determine the branch type:
   - Prefer `--feature` (default) unless the user says "hotfix", "urgent", or references an incident
   - Map context to derive `--feature` or `--hotfix`

2. Derive the slug from the ticket key:
   - Extract ticket key from the user's message (e.g., "TICKET-123")
   - Convert to a slugified name (lowercase, hyphens)

3. Show the planned worktree creation:
   - Run `wt create <app> <slug> --feature --ticket <KEY> --dry-run` first
   - Display the plan to the user

4. If the user confirms or the plan looks good:
   - Run `wt create <app> <slug> --feature|--hotfix --ticket <KEY>`
   - Report the worktree path and any relevant URLs

## List worktrees

**Triggers:** "list", "what worktrees", "show my worktrees"

- Run `wt list`
- Present the output to the user

## Open a worktree

**Triggers:** "open", "switch to", "go to", "cd into"

1. Identify the target slug from the user's message
2. Run `wt open <app> <slug>`
3. Return the worktree path to the user

## Destroy a worktree

**Triggers:** "destroy", "delete", "remove worktree", "clean up"

**WARNING:** This is destructive and cannot be undone.

1. Identify the target slug from the user's message
2. Show what will be destroyed:
   - Run `wt destroy <app> <slug> --dry-run`
   - Display the plan clearly

3. Require explicit confirmation:
   - Ask the user to confirm the destruction
   - Do not proceed without an explicit "yes" or similar affirmation

4. Once confirmed, execute the destruction:
   - Run `wt destroy <app> <slug>`
   - Report success

## General notes

- Always invoke `wt` via the repository's `bin/wt` script; never fabricate environment names
- Read actual environment names from `wt list` output
- When in doubt about parameters, run `--dry-run` first and show the user the plan before executing
- The `--ticket` parameter ties the worktree to a ticket in the registry
