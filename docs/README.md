# Loci — ownership-aware notes, projects & workspaces for Neovim

Loci brings the **loci-core V2 engine** into Neovim: tracked markdown documents (adoption),
projects (a document whose mapped kind is `project`), declarative **workspaces**, a hard relation
graph, and FTS5 search — served by the `loci-lsp` language server.

> **Realigned August 2026 (V2).** The engine underneath was clean-roomed (blue-sky V2) and then
> refactored (the 30-commit findings pass). The plugin now speaks the **V2 wire contract** —
> registry-driven feature methods (`loci/<wire>`) — not the old `loci/op` /
> `workspace/executeCommand` / `loci/commands` protocol. Anything in older docs about
> **activation, the `.loci/content/` jail, the palette command table, doctor, reconcile,
> `repository.init`, or `start-work`** is obsolete: those engine capabilities were deliberately
> deleted (arch §18) and are not coming back.

## What it is (the mental model)

`lua/loci/init.lua` is a **thin LSP client** — one file, no loci logic. Every semantic decision
(what a valid document is, what a workspace contains, what a code action does) lives in the
external **`loci-core`** engine, reached over **`loci-lsp`**:

```
Neovim  ──▶  lua/loci/init.lua  ──▶  loci-lsp (pygls host)  ──▶  loci-core V2 kernel
 (you)        thin client              the engine's transport          all the logic
```

- **The engine is the sole writer.** The client never edits frontmatter. It runs a feature
  command (`documents/set_status`, `relations/add_project`, `workspaces/put`, …), the engine
  writes the file under its own ownership rules, and the client reloads the buffer
  (`:checktime`). Edits always go through a command or code action — never a raw buffer edit.
- **Standard LSP features are "free".** Diagnostics are served by the server (pull-based; real
  UTF-16 ranges), code actions use the editor's existing `<localleader>a`. The client wires none
  of these — it adds the hubs (status, workspaces, projects, health, …) and the code-action
  apply-then-reload interception.
- **Host state stays in the host** (arch §6.7/§4.3). V2 has no engine-side "active workspace",
  no `current` pointer, no editor state. The client owns the tab-pinned workspace id
  (`vim.t.loci_workspace_id`) and the last observed revision/consistency (`vim.t.loci_state`).

## Core concepts

| Concept | What it is |
|---|---|
| **Vault** | A directory containing `.loci/vault.toml` (the V2 manifest). One `loci-lsp` server runs per vault. |
| **Document** | A markdown file under the vault. **Unmanaged** by default (an informational diagnostic); **adoption** (`documents/adopt`, as a code action or `:LociAdopt`) stamps a stable id into the canonical `loci:` region. |
| **Project** | A managed document whose policy-mapped kind is `project` — there is no separate project entity (arch §11.2). |
| **Workspace** | A declarative lens over the vault: a source-controlled manifest at `.loci/workspaces/<id>.yaml` naming documents (ref/role) and files (path/role). You **pin** one per tab; the engine stores no "current". |
| **Linked file** | A vault file attached to a workspace manifest with a role (`implementation`, `reference`, `related`, `documentation`, `test`). |
| **Graph / search** | Backlinks, neighbors, traversal, broken links, missing attachments, ambiguous links, orphans (hard graph), and FTS5 full-text search. |

### Ownership model

| Concern | Owner |
|---|---|
| Notes, prose, links | Markdown / Obsidian |
| Task status, priority, dates, timers | TaskNotes ([boundary](tasknotes-delegation.md)) |
| Project/workspace membership, adoption, graph, search | **loci-core (the engine)** |
| Session state (which workspace this tab is on), staleness display | **loci.nvim (the host)** |

### Workspace pinning — what replaced "activation"

The old engine returned an *editor-state plan* on activation and the client applied it (tcd,
resession, haunt, wayfinder). V2 deleted that machinery on purpose (arch §6.7: "no shared
`current`… Core returns a host-neutral WorkspaceView and never knows plugin names"). The client
now keeps it simpler and honest:

- `:LociWorkspaces` lists workspaces → pick one → it becomes this **tab's** pinned workspace
  (`vim.t.loci_workspace_id`, shown in the statusline).
- `:LociStatus` shows the pinned workspace's view (documents + files) and offers
  archive/unarchive + refresh.
- Nothing is written back to the engine about tabs, sessions, or trails — that state is yours.

---

## Getting started

### 1. Prerequisites

- **The Nix fleet (recommended):** nix-nvim consumes this repo's flake — the plugin lands on the
  runtimepath and `loci-lsp` on PATH automatically.
- **Manual / engine dev:** a local checkout of **loci-core** with the V2 LSP host built (the
  pygls transport + console scripts ship in the engine's single wheel, project 32).

### 2. Install

```bash
nix build .#loci-nvim    # the plugin derivation
nix build .#loci-lsp     # the server binary (re-exported from loci-core's flake)
```

> ⚠️ **The #1 onboarding trap: PATH.** If `loci-lsp` is not on Neovim's PATH, the client
> **silently fails to attach** — no error, loci just does nothing. Always verify:
>
> ```bash
> which loci-lsp && loci-lsp --help; echo "exit=$?"
> ```

### 3. Create a vault

A vault is a directory with `.loci/vault.toml`. The engine never initializes on open
(`Loci.open` raises `VaultNotInitialized`) — create it with the engine's init verb:

```bash
mkdir -p ~/notes/myvault && cd ~/notes/myvault
loci init .    # create the vault manifest (.loci/vault.toml)
```

Opening a vault file before init shows a one-time "not initialized" warning instead of silently
attaching to a doomed server.

### 4. Open it in Neovim

Open **any** file under the vault with `nv` (the Nix-wrapped `nvim`). The client auto-attaches on
`BufReadPost`/`BufNewFile` for any file beneath a `.loci/` directory (with a `vault.toml`). Verify:

```vim
:lua =vim.lsp.get_clients({ name = 'loci' })[1] ~= nil   " -> true
```

---

## Using it in the editor

### Automatic surfaces

- **Diagnostics** — served by the server with **real UTF-16 ranges** (D-041). V2 emits four
  families: `unmanaged` (informational — **filtered out by the client by default**, arch §13;
  flip with `:LociToggleUnmanaged` or `vim.g.loci_show_unmanaged`), `missing_target`,
  `ambiguous_link`, `degraded_identity` (plus the pre-existing envelope/YAML families). Rendered
  by `vim.diagnostic`.
- **Statusline staleness** — the last feature response's revision/consistency is exposed as
  `require("loci").statusline()` (`<rev>` current, `<rev>!` stale-index read — see
  [state-ownership.md](state-ownership.md)); nix-nvim renders it as `loci:<rev>[!]`.
- **Code actions** — `<localleader>a` (tiny-code-action) on a document offers `documents.adopt`,
  `documents.format_owned`, `documents.set_status`. The client intercepts
  `loci.action.execute`, applies, reloads, and surfaces refusals (e.g. `set_status` refuses
  values that would not reparse equal — D-027).
- **Save conflicts** — saves are CAS source commits (D-041): if a concurrent external edit
  changed the file between open and save, you get a "save not committed" notice instead of a
  silent overwrite.

### Commands & keymaps

All hubs are snacks pickers. The `<leader>l` group:

| Keymap | Command | What |
|---|---|---|
| `<leader>lp` | `:LociPalette` | The client's own verbs (note/project/workspace/health/search/graph/link/…) |
| `<leader>ls` | `:LociStatus` | Pinned workspace's context hub (documents, files, link file, archive, refresh) |
| `<leader>lw` | `:LociWorkspaces` | List workspaces → pin one for this tab; create a workspace |
| `<leader>lP` | `:LociProjects` | Managed documents whose kind is `project` → open |
| `<leader>ld` | `:LociDoctor` | Vault health: refresh + diagnostics summary + broken/ambiguous links & orphans |
| `<leader>lnd` | `:LociDaily` | `documents/create` with today's date (a client-side template) |
| `<leader>lns` | `:LociScratch` | `documents/create` with a prompted name |
| `<leader>lnn` | `:LociNote` | `documents/create` (name is validated — no `/`, D-028) |
| — | `:LociSearch` | FTS5 full-text search over managed + unmanaged documents |
| — | `:LociBacklinks` | Inbound resolved relations for the current note |
| — | `:LociNeighbors` | `graph/neighbors` of the current note (backlinks + outgoing targets) |
| — | `:LociTraversal` | `graph/traversal` from the current note (rows carry depth) |
| — | `:LociProjectMembers` | `graph/project_members` — resources whose properties name the current note as a project |
| — | `:LociAdopt` | Standalone `documents/adopt` for the current buffer's document (preview-then-apply) |
| — | `:LociMove` | `documents/move` — prompt a destination, preview, apply, open the moved file |
| — | `:LociLinkFile` | Link the current buffer's file to the tab-pinned workspace (role picker) |
| — | `:LociToggleUnmanaged` | Flip `vim.g.loci_show_unmanaged` (unmanaged diagnostic rows) |

That's the **entire** command surface — document, graph, and workspace verbs included. Anything
more specific (set status, archive, adopt-as-code-action) is reached through a code action or the
status hub.

> `<leader>n` (top-level "Notes") is a **separate** group for Obsidian/TaskNotes/haunt — not loci.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Loci does nothing; no client attaches | `loci-lsp` not on PATH. `which loci-lsp` outside the devenv; the flake re-export comes from loci-core. |
| "vault not initialized (missing .loci/vault.toml)" | Run `loci init` in the vault and reopen a file. |
| "open a file inside a loci vault" | The current buffer isn't under a `.loci/` directory. Reads/effects need a vault buffer. |
| "no workspace pinned in this tab" | Pick one with `:LociWorkspaces` (the engine has no "current" — the tab owns it). |
| "save not committed: …" | A concurrent external edit changed the file since you opened it (CAS conflict, D-041). Reload and re-apply your edit. |
| "set_status refused: unsupported_new_value" | The value would not reparse equal (e.g. `yes`, `no`, `123`, `""` — D-027). Use a writable value. |
| Code action applied but buffer looks stale | The engine wrote the file; the client ran `:checktime`. An unsaved buffer won't be clobbered — save or `:e`. |

More: [troubleshooting.md](troubleshooting.md).

## Limitations

By design (engine decisions, arch §18):

- **No activation/editor-state** — the engine deleted it; the client pins workspaces per tab
  instead.
- **No tags writer** — V2 deliberately has none; edit `tags:` by hand.
- **No completion** — V2 has no completion provider.
- **No whole-vault doctor** — replaced by `:LociDoctor` (refresh + graph findings + diagnostics
  summary).
- **No `.loci/content/` jail** — documents live at their real vault-relative paths.

## Deeper topics

- [Workspace lifecycle](workspace-lifecycle.md) — create, pin, archive, refresh
- [State ownership](state-ownership.md) — sole-writer model; what the host owns
- [TaskNotes delegation](tasknotes-delegation.md) — why loci owns no task state
- [Obsidian boundary](obsidian-symlink-setup.md) — documents at real paths
- [Troubleshooting](troubleshooting.md)

## For maintainers

The client is a single file: `lua/loci/init.lua`. It's **clean-room**, written against the V2
wire contract — see `.scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md` (the
engine host must implement exactly that; the fakeserver `fakeservers/fs_v2.py` is the executable
reference). The engine lives in a separate repository; don't add client-side logic that belongs
server-side. The Lua suite (`bash .scratch/tests/run-tests.sh`, also the flake check
`loci-nvim-tests`) gates the client against the contract without needing the real engine.
