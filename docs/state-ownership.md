# State ownership

The guiding rule of the rewritten client: **the engine is the sole writer, and the single source of truth.**
The editor holds no loci state beyond one runtime pointer.

## The engine owns durable state

All durable loci state — projects, workspaces, membership, linked files, the active-workspace pointer — lives
inside the `loci-core` engine and is reached only over `loci-lsp`. The client:

- **reads** via the `loci/op` request (a default-deny allowlist of read ops);
- **writes** only by asking the engine to run an effect command (`workspace/executeCommand`), then reloading
  the buffer with `:checktime`.

The client never authors a `WorkspaceEdit` or rewrites frontmatter itself. This is why every change goes
through the palette, the status hub, or a code action — and why a contextual write first runs as a **dry-run**
the engine projects, so you preview the result before applying.

## The editor owns one runtime pointer

| State | Where | Authoritative? |
|---|---|---|
| Active workspace (durable) | engine | yes |
| `vim.t.loci_workspace_id` | Neovim, tab-local | no — a runtime convenience |

`vim.t.loci_workspace_id` is set by `require("loci").activate(...)` and is what the statusline and other
tab-local UI read. It mirrors the engine's notion of the active workspace for the current tab; it is **not**
the source of truth. If they ever disagree, the engine wins — re-activate.

## The markdown knowledge layer

Knowledge notes are real markdown files under `<vault>/.loci/content/`, carrying a `loci_id` in frontmatter.
They are co-owned: you edit prose freely, but loci-managed frontmatter (ids, project links, membership) is
written by the engine. Diagnostics (`loci-doctor`) and code actions are how the engine keeps that frontmatter
canonical.
