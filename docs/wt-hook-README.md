# Worktree SessionStart Hook

The worktree hook is a read-only SessionStart hook for Claude Code that detects work-in-progress (WIP) in managed repositories and suggests creating an isolated worktree for the feature.

## What the Hook Does

The hook:
- **Detects** whether your current directory is inside a managed repository tracked in `etc/wt/apps.conf`
- **Identifies** work-in-progress (WIP): either uncommitted changes OR a branch that is not the base/main branch
- **Suggests** worktree creation via the `/worktree-env` skill (e.g., "nouveau worktree GEL-123")
- **Never auto-creates** anything — all operations require explicit user action

When you open a Claude session in a managed repo with WIP changes, the hook injects a suggestion into the session context:

```
wt · myapp : travail en cours (branche feature/GEL-123, 5 fichier(s) modifié(s)).
Pour isoler un nouveau ticket : demande « nouveau worktree <TICKET> » (→ wt create).
```

## Installation

To register the hook in your Claude settings:

```bash
bin/wt-hook-install
```

This:
1. Adds the hook to `~/.claude/settings.json` under `hooks.SessionStart`
2. Creates a symlink to the `/worktree-env` skill in `~/.claude/skills/worktree-env`

**Important:** Open a new Claude session after installation for the hook to take effect.

## Uninstallation

To remove the hook:

```bash
bin/wt-hook-install --uninstall
```

This removes the hook entry from `~/.claude/settings.json` and cleans up the skill symlink.

## Using the /worktree-env Skill

Once the hook detects WIP, you can interact with worktrees using natural language commands in Claude:

### Create a new worktree

```
nouveau worktree GEL-123
```

or

```
start GEL-456
```

Claude will:
1. Show you a dry-run of what will be created
2. Ask for confirmation
3. Create the isolated worktree with the ticket key linked

### List your worktrees

```
liste mes worktrees
```

Returns the current list of active worktrees for the app, including their paths and running environments.

### Open a worktree

```
go to GEL-123
```

or

```
open worktree GEL-456
```

Returns the path to the worktree so you can navigate to it in your terminal.

### Destroy a worktree

```
supprime le worktree GEL-123
```

or

```
delete worktree GEL-456
```

Claude will:
1. Show you what will be destroyed (dry-run)
2. Ask for explicit confirmation (required for destructive operations)
3. Delete the worktree once confirmed

## Manual End-to-End Example

Here's the full workflow:

### 1. Install the hook

```bash
cd ~/Project/MyApp
bin/wt-hook-install
# Open a NEW Claude session
```

### 2. Make changes in a managed repo

On a feature branch with uncommitted changes:

```bash
git checkout -b feature/GEL-123
echo "work" > src/file.txt
# (don't commit yet)
```

### 3. Open a Claude session

```bash
cd ~/Project/MyApp/src
# Open Claude Code or start a new session
```

The hook detects your WIP and injects:

```
wt · myapp : travail en cours (branche feature/GEL-123, 1 fichier(s) modifié(s)).
Pour isoler un nouveau ticket : demande « nouveau worktree GEL-123 » (→ wt create).
Envs actifs : staging → https://staging-app.internal · production → https://app.internal
```

### 4. Create an isolated worktree

Ask Claude:

```
nouveau worktree GEL-123
```

Claude runs a dry-run and shows:

```
Planned worktree creation:
  app: myapp
  branch type: feature
  slug: GEL-123
  ticket: GEL-123
  location: ~/Project/MyApp/.wt/worktrees/feature-GEL-123
```

Confirm, and Claude creates the worktree in isolation.

### 5. List worktrees

Ask Claude:

```
liste mes worktrees
```

Response:

```
Current worktrees for myapp:
  feature-GEL-123 (~/Project/MyApp/.wt/worktrees/feature-GEL-123)
    → staging: https://staging-app.internal
    → production: https://app.internal
```

### 6. Destroy the worktree

When done, ask Claude:

```
supprime le worktree GEL-123
```

Claude shows what will be deleted and requires explicit confirmation before proceeding.

---

## Configuration

The hook reads managed repositories from `etc/wt/apps.conf`:

```
app|repo|type|base|compose|install
myapp|/home/user/Project/MyApp|symfony|develop|.docker/docker-compose.yml|make install
```

Each line defines:
- `app`: Application name (e.g., myapp)
- `repo`: Full path to the repository root
- `type`: Repository type (symfony, laravel, nextjs, etc.)
- `base`: Base/main branch name (e.g., develop, main, master)
- `compose`: Docker Compose file path (relative to repo root)
- `install`: Installation command

## Troubleshooting

**Hook doesn't appear in new sessions:**
- Run `bin/wt-hook-install` again and make sure to open a completely new Claude session

**Hook triggers unexpectedly:**
- The hook runs for any directory inside a managed repo — this is by design
- To silence it, switch to a branch matching the base branch AND commit all changes

**Worktrees fail to create:**
- Check that `wt` is available in `$PATH` or via the repository's `bin/wt` script
- Verify the app is registered in `etc/wt/apps.conf`
- Run `bin/wt doctor` to diagnose the environment
