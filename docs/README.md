# Loci — project-aware notes & workspaces

Loci brings a project-management engine into Neovim: tracked markdown notes, projects, and named
**workspaces** whose editor state (annotations, session, trail, working directory) is saved and restored as
you switch between them.

> **Rewritten June 2026.** The old ~14k-line in-editor monolith was replaced by a thin LSP client over the
> external `loci-core` engine. If you remember commands like `:LociInit`, `:LociRefresh`, `:LociTrailCreate`,
> or `require("loci").setup{}` — those are **gone**. See [Commands & keymaps](#commands--keymaps) for the
> current surface.

## What it is (the mental model)

The plugin at `lua/loci/` is a **thin LSP client** — a single `init.lua`. It holds **no loci logic**. Every
semantic decision (what's a valid note, what a workspace contains, what a code action does) lives in the
external **`loci-core` engine**, reached over the **`loci-lsp`** language server.

```
Neovim  ──▶  lua/loci/init.lua  ──▶  loci-lsp (server)  ──▶  loci-core engine
 (you)        thin client            LSP transport            all the logic
```

Two consequences worth internalizing up front:

- **The engine is the sole writer.** The client never edits your frontmatter directly. It asks the engine to
  perform an effect, the engine writes the file, and the client reloads the buffer (`:checktime`). Edits always
  go through a command or code action — never a raw buffer edit. (See [state ownership](state-ownership.md).)
- **Standard LSP features are "free."** Completion rides blink's `lsp` source, diagnostics are pushed by the
  server, code actions use the editor's existing `<localleader>a`. The client wires none of these — it only
  adds the hubs (palette, status, …) and the activation flow.

## Core concepts

| Concept | What it is |
|---|---|
| **Vault** | A directory containing a `.loci/` folder. The root the engine operates on; one `loci-lsp` server runs per vault. |
| **Knowledge note** | A markdown file the engine tracks (carries a `loci_id` in frontmatter), stored under `<vault>/.loci/content/`. |
| **Project** | A titled grouping with a status (`active`, …). Notes can be linked to a project. |
| **Workspace** | A named working context you "activate." Activation restores its editor state. The unit you start and switch work on. ([lifecycle](workspace-lifecycle.md)) |
| **Linked file** | A repository file attached to a workspace with a role (`implementation`, `reference`, `related`, `documentation`, `test`). |

### Ownership model

Loci orchestrates; other tools own their own data. (Details: [state ownership](state-ownership.md),
[TaskNotes boundary](tasknotes-delegation.md), [Obsidian boundary](obsidian-symlink-setup.md).)

| Concern | Owner |
|---|---|
| Notes, prose, links | Markdown / Obsidian |
| Task status, priority, dates, timers | TaskNotes |
| Code annotations | haunt.nvim |
| Exploration trails | wayfinder.nvim |
| Editor tab sessions | resession |
| Tab/window grouping | Tabby / Neovim |
| Projects, workspaces, linked files, orchestration | **loci-core (the engine)** |

### Activation — what moves when you switch workspace

Activating a workspace asks the engine for an *editor-state plan* and applies each present block
(pcall-guarded, so a missing plugin just no-ops):

- working directory → `:tcd`
- [haunt.nvim](../haunt) annotation data dir
- [resession](../resession) tab session
- [wayfinder.nvim](../wayfinder) trail
- sets `vim.t.loci_workspace_id` (shown in the statusline as `loci:<id>`)

It then observes the git branch you actually checked out and writes it back to the engine. Tabby labels are
presentational and intentionally skipped (the editor owns the live tab).

---

## Getting started

### 1. Prerequisites

- [`uv`](https://docs.astral.sh/uv/) on PATH.
- A local checkout of **loci-core** (on this machine: `~/Documents/Projects/loci-core`).
- `~/.local/bin` on your PATH (where `uv tool` installs binaries).

### 2. Install the two tools

Loci is **not** a `vim.pack` plugin and **not** a Nix dependency — it's two `uv` tools installed from the
loci-core source tree:

```bash
# the CLI (provides `loci`) — used to create vaults and start work
uv tool install --from ~/Documents/Projects/loci-core loci-core

# the language server (provides `loci-lsp`) — what Neovim talks to
uv tool install --from ~/Documents/Projects/loci-core/lsp loci-lsp
```

> ⚠️ **The #1 onboarding trap: PATH.** If `loci-lsp` is not on Neovim's PATH, the client **silently fails to
> attach** — no error, loci just does nothing. Always verify outside the devenv shell:
>
> ```bash
> which loci-lsp && loci-lsp --help; echo "exit=$?"
> ```
>
> Fix PATH before debugging anything else. (The client also shows a one-time warning when it can't find
> `loci-lsp`.)

After any change to the loci-core engine, refresh the server with `--force`:

```bash
uv tool install --force --from ~/Documents/Projects/loci-core/lsp loci-lsp
```

### 3. Create a vault and start work

```bash
mkdir -p ~/notes/myvault && cd ~/notes/myvault
loci repository.init --vault .          # creates .loci/
loci start-work "Spike the parser"      # note + workspace + activate, in one shot
```

### 4. Open it in Neovim

Open **any** file under the vault with `nv` (the Nix-wrapped `nvim`). The client auto-attaches on
`BufReadPost`/`BufNewFile` for any file beneath a `.loci/` directory. Verify:

```vim
:lua =vim.lsp.get_clients({ name = 'loci' })[1] ~= nil   " -> true
:LspLog                                                  " -> should be clean
```

---

## Using it in the editor

### Automatic surfaces (no keymaps)

- **Completion** — on a frontmatter `key:` line in a `.loci/content/` note, typing `:` completes the key's
  allowed values through blink's normal completion menu.
- **Diagnostics** — the engine's `doctor` findings are pushed on open/save of a note (source `loci-doctor`),
  rendered by `vim.diagnostic`. *(Findings currently anchor at line 0 — see [Limitations](#limitations).)*
- **Code actions** — `<localleader>a` (tiny-code-action) on a note offers contextual verbs (set status, edit
  tags, link to project, …). Each shows a **dry-run diff preview** before applying; the engine writes, the
  buffer reloads.

### Commands & keymaps

All hubs are snacks pickers. The `<leader>l` group:

| Keymap | Command | What |
|---|---|---|
| `<leader>lp` | `:LociPalette` | Command palette — every engine effect, prompting each argument by type |
| `<leader>ls` | `:LociStatus` | Status / context hub — active workspace, its project, notes & linked files; link-a-file, reconcile, deactivate |
| `<leader>lw` | `:LociWorkspaces` | Switch workspace (activate) |
| `<leader>lP` | `:LociProjects` | Browse projects → open the project note |
| `<leader>ld` | `:LociDoctor` | Vault health findings; "Fix all missing loci_id" bulk-fix |
| `<leader>lnd` | `:LociDaily` | Create/open today's daily note |
| `<leader>lns` | `:LociScratch` | Create/open a scratch note |
| `<leader>lnn` | `:LociNote` | New note (prompts title etc.) |

That's the **entire** command surface — eight commands. Anything more specific (create a workspace, link a
file, set status, archive) is reached through the palette, the status hub, or a code action.

> `<leader>n` (top-level "Notes") is a **separate** group for Obsidian/TaskNotes/haunt — not loci. Loci notes
> live under `<leader>ln`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Loci does nothing; no client attaches | `loci-lsp` not on PATH. `which loci-lsp` outside devenv; reinstall the uv tool. |
| "open a file inside a loci vault" | The current buffer isn't under a `.loci/` directory. Reads/effects need a vault buffer. |
| Two completion menus | Should never happen — the client deliberately does **not** call `vim.lsp.completion.enable` (blink carries it). |
| Code action applied but buffer looks stale | The engine wrote the file; the client runs `:checktime`. An unsaved buffer won't be clobbered — save or reload. |
| Server behaves like an old version | You changed the engine. Refresh with `uv tool install --force …` (above). |

More: [troubleshooting.md](troubleshooting.md).

## Limitations

By design or pending engine work:

- **Diagnostics anchor at line 0** (whole-file), not the offending frontmatter line — a server-side follow-on.
- **Completion fills the scalar after `key:`** only, not YAML list-item positions — a server-side follow-on.
- **`doctor_fix` only fixes `missing_loci_id`** — the one safe bulk fix the engine offers today.
- **Removed on purpose:** haunt/trail CRUD (owned by `haunt.nvim` / `wayfinder.nvim`), workspace clone,
  repository verify/repair. The old "refresh" is now the engine's `reconcile` (a row in the status hub).

## Deeper topics

- [Workspace lifecycle](workspace-lifecycle.md) — create, switch, knowledge & linked files, archive, activation
- [State ownership](state-ownership.md) — sole-writer model; durable vs runtime state
- [TaskNotes delegation](tasknotes-delegation.md) — why loci owns no task state
- [Obsidian boundary](obsidian-symlink-setup.md) — what the vault exposes to Obsidian
- [Troubleshooting](troubleshooting.md)

## For maintainers

The client is a single file: `lua/loci/init.lua`. It's **clean-room** — written against the `loci-lsp` wire
protocol, not copied from loci-core's Lua test harness. The header comment documents the protocol surface and
the `--force` refresh command. The engine lives in a separate, read-only repository; don't add client-side
logic that belongs server-side.
