# Workspace lifecycle

A workspace is a **declarative lens** over the vault: a source-controlled YAML manifest at
`.loci/workspaces/<id>.yaml` (arch §6.7) naming documents (ref + role) and files (path + role).
There is no engine-side "active workspace" — a tab pins one, and the pin is host state.

Everything below is reached through `:LociWorkspaces`, `:LociStatus`, code actions, or the
palette. There are no `:LociWorkspace*` commands.

## Create

```vim
:LociWorkspaces   " <leader>lw — picker: "＋ create workspace…" prompts a name
```

`workspaces/put` previews its manifest write (the feature's declared pure preview), then commits
on confirm. The created workspace becomes the tab's pin.

## Pin / switch

```vim
:LociWorkspaces      " <leader>lw — pick a workspace; it becomes THIS tab's pin
```

There is no activation: the engine returns no editor-state plan (no cwd/resession/haunt/wayfinder
blocks — those were deleted with the old engine, arch §6.7). The pin (`vim.t.loci_workspace_id`)
is what the statusline shows; sessions, trails, and working directories are yours to manage.

## What a workspace contains

```vim
:LociStatus          " <leader>ls — the pinned workspace's context hub
```

The hub renders the `WorkspaceView`: the manifest's `project`, its **documents** (ref, role,
resolved state, current path) and **files** (path, role). Rows open the file at its real
vault-relative path; an unresolved ref shows its state (`Missing`/`Ambiguous`) instead of
pretending.

## Archive / unarchive

The status hub's `▸ archive workspace` row calls `workspaces/archive` (typed sugar, D-029).
Archiving changes exactly the manifest's `archived:` line — composition is preserved (the
workspace keeps its documents and files) and the write is CAS-protected. It does **not** delete
markdown or anything else.

## Refresh

V2's compiler refresh is `maintenance/refresh` (read-your-writes is automatic; this is for
explicit index maintenance). The status hub offers `▸ refresh index`; `:LociDoctor` also
refreshes as part of the health report. `refresh` reports a real `changed_sources` count and a
per-code diagnostics summary.

> **Gone for good:** the old `workspace.create`/`start-work` palette verbs, activation with
> editor-state plans, deactivation with session/trail saves, and workspace clone. The engine
> deleted them (arch §6.7, §18); the client does not fake them.
