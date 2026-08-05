# State ownership

The guiding rule of the client: **the engine is the sole writer of vault files, and the sole
source of semantic truth.** The editor holds no loci logic and no durable loci state.

## The engine owns semantics and writes

All semantic decisions — what a valid document is, what a workspace contains, how a code action
commits — live in `loci-core` (the V2 kernel: `documents/*`, `relations/*`, `workspaces/*`,
`maintenance/*`, `search/*`, `graph/*`). The client:

- **reads** via registry feature methods (`loci/<wire>`, e.g. `loci/documents/list`),
  returning the `{ok, value}` envelope;
- **writes** only by running a feature command (or `workspace/executeCommand`
  `loci.action.execute` for code actions), then reloading the buffer with `:checktime`.

The client never authors a `WorkspaceEdit` or rewrites frontmatter itself. Every write the engine
makes is a **pure planned patch** with source-hash and span-byte preconditions (arch §12.1): it
can only touch the regions it owns — the canonical `loci:` region and the one shared property it
is asked to write (`status`). Everything outside those spans is byte-identical. Deletion is not a
capability at all (arch §11.2) — remove files with Obsidian, a file manager, or a shell; the
compiler observes the removal like any other change.

## The host owns session state (arch §6.7 / §4.3)

V2 deliberately holds **no** shared `current` pointer, no activation, no editor state — "Core
returns a host-neutral WorkspaceView and never knows plugin names." What the client keeps:

| State | Where | Notes |
|---|---|---|
| Tab-pinned workspace id | `vim.t.loci_workspace_id` (tab-local) | Set by `:LociWorkspaces`; shown in the statusline as `loci:<id>`. Purely host-side. |
| Last observed revision/consistency | `vim.t.loci_state` (`{revision, consistency}`) | Filled from every feature response that carries one; lets a statusline show staleness (arch §10.2 — every result names its mode + revision). |

If you switch tabs or sessions, the pin does not follow — that is the honest model: the engine
does not know and the client does not pretend otherwise.

## Documents are real files, not a jail

V2 removed the `.loci/content/` content jail (arch §6.1: "Content is not confined beneath an
engine-owned content jail"). Documents live at their **real vault-relative paths**. There is no
hidden second tree the engine owns.
