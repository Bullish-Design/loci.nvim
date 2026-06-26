# Workspace lifecycle

A workspace is a named working context inside a vault. It may own a git branch/worktree binding, a resession
tab session, a haunt annotation data dir, a wayfinder trail, associated knowledge notes, and linked source
files. Activating it restores that editor state.

Everything below is reached through the eight client commands, the palette, the status hub, or code actions —
there are no dedicated `:LociWorkspace*` commands anymore.

## Create

The fastest path is the CLI one-shot, which creates a note, a workspace, and activates it:

```bash
loci start-work "Spike the parser"
```

Inside the editor, create one via the palette (`<leader>lp` → `workspace.create`).

## Switch (activate)

```vim
:LociWorkspaces      " <leader>lw — pick from the list, activates on confirm
```

Or programmatically: `:lua require("loci").activate("<workspace_id>")`. Activation applies the engine's
editor-state plan (cwd, haunt, resession, wayfinder) and sets `vim.t.loci_workspace_id`. See
[the activation section in the README](README.md#activation--what-moves-when-you-switch-workspace).

## Associate knowledge notes & linked files

From a note buffer, use code actions (`<localleader>a`) — e.g. adopt the note, link it to a project. From the
**status hub** (`<leader>ls`):

- `▸ link a file to this workspace…` — pick a file, choose a role (`implementation`/`reference`/`related`/
  `documentation`/`test`).
- each linked file has an inline `▸ unlink` row.

Knowledge membership and project links are engine effects; the client previews the dry-run and reloads after.

## Reconcile

The old "refresh" pipeline is now the engine's **reconcile** pass (rebuild/repair). Run it from the status hub:

```
<leader>ls → ▸ reconcile workspace
```

## Deactivate / archive

- Deactivate the current workspace: status hub → `▸ deactivate workspace`.
- Archive a workspace: palette (`<leader>lp` → `workspace.archive`). Archiving marks it archived; it does not
  delete markdown or integration data.

> **Clone is gone.** Workspace clone existed in the old monolith and was culled in the rewrite. There is no
> replacement — create a new workspace instead.
