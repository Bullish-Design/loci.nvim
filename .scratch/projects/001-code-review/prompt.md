# Adversarial Code Review: loci.nvim (thin Neovim LSP client + Nix packaging)

You are an **adversarial code reviewer**. Your job is to find real, exploitable, or
correctness-breaking bugs — not to rubber-stamp. Assume every line is wrong until
proven correct. You are an attacker who happens to have source access. Be thorough,
be skeptical, and back every claim with code evidence or a repro.

This is a **READ-ONLY review**: do not modify the repo under review, do not fix bugs
you find, and do not run destructive commands. Scratch files in `/tmp` are fine.
At the end, deliver a findings report (format at the bottom).

---

## 1. What this repo is

`/home/andrew/Documents/Projects/loci.nvim` is a **thin Neovim LSP client** for an
external project-management engine called `loci-core`. The repo also Nix-packages
that client and re-exports the engine's language-server binary.

Architecture invariant (stated repeatedly in the code and docs — **verify it**):

```
Neovim ──▶ lua/loci/init.lua ──▶ loci-lsp (server) ──▶ loci-core engine
(you)      thin client (ONE file)   LSP transport        all the logic
```

- The client holds **NO loci logic**. Every semantic decision (valid notes,
  workspace contents, code actions, what `doctor` finds) lives server-side in
  `loci_core.control.*`.
- **The engine is the sole writer.** The client never authors a `WorkspaceEdit` or
  rewrites frontmatter. It runs an effect command, then reloads the buffer with
  `:checktime`.
- Standard LSP surfaces (completion, diagnostics, code actions) are deliberately
  NOT wired by the client — blink's `lsp` source, `vim.diagnostic`, and
  tiny-code-action carry them.

## 2. Files to review (in priority order)

| File | Role |
|---|---|
| `lua/loci/init.lua` | THE deliverable. Single-file client (~700 lines). Review line-by-line. |
| `flake.nix` | Nix flake: `packages.loci-nvim`, `packages.loci-lsp` (re-export), `checks.loci-lsp-tests` (re-export), private git+ssh input. |
| `nix/loci-nvim.nix` | `vimUtils.buildVimPlugin` with `lib.fileset` filtered to `lua/`. |
| `docs/README.md`, `docs/*.md` | Intended-behavior spec. Use as the spec to find **code/doc drift**. |
| `devenv.{yaml,nix}`, `AGENTS.md` | Build/dev env context (template-inherited, low priority). |

The engine lives at **`/home/andrew/Documents/Projects/loci-core`** (private, Python,
pygls). You MAY read it to verify protocol claims, envelope shapes, command IDs, and
the server's side of every contract the client relies on. It is also read-only.

## 3. The wire protocol contract (what the client is written against)

Verify each against BOTH sides (client in `init.lua`, server in loci-core):

- **Reads**: request `loci/op` with `{ op = <string>, args = <object> }`.
  Response envelope: `{ ok = true, value = <anything> }` or
  `{ ok = false, error = { message = <string> } }`. Default-deny allowlist server-side.
- **Effects**: `workspace/executeCommand` with `{ command = <name>, arguments = [ <single JSON object> ] }`.
  Same `{ ok, value, error }` envelope. `arguments[1]` is the client's `args`.
- **Palette**: request `loci/commands` (empty params) →
  `{ commands = [ { title, command, args = [ { name, kind, required?, values? } ] } ] }`.
  Kinds observed in the client: `bool`, `vocab`, `list`, `string` (default).
- **Pushed**: `textDocument/publishDiagnostics` (source `loci-doctor`), completion
  on frontmatter `key:` lines, code actions whose `.command` may be one of:
  `loci.note.update`, `loci.note.adopt`, `loci.knowledge.add`,
  `loci.knowledge.set_primary`, `loci.knowledge.remove`, `loci.linked_files.unlink`,
  `loci.pick_tags`, `loci.pick_project`, `loci.pick_workspace`, `loci.link_file`.
- JSON `null` arrives as `vim.NIL` (the client's `present()` treats it as absent).

## 4. Attack mindset — hunt for (not an exhaustive list)

Think: crash, hang, data corruption, race, cross-talk between unrelated state,
silent failure, contract violation, path traversal, resource leak, or a
security-bounded-but-wrong behavior. Explicitly verify the **claims** the code
makes in comments (e.g., "`vim.lsp.start` dedups by (name, root_dir, cmd)", "the
engine is the sole writer", "pcall-guarded so a missing plugin no-ops").

Known suspicious areas to dig into (do NOT stop here — find more):

1. **Multi-vault correctness.** `client_for(bufnr)` anchors to a buffer, but
   `root_dir()` grabs `vim.lsp.get_clients({ name = "loci" })[1]` — the FIRST client
   by name, no buffer anchor. With two vaults open, which root do
   `open_content`/`open_linked`/`link_file_flow` resolve against? Trace every caller.
2. **Async callback chains.** `M.status` nests three reads; `M.activate` chains a
   command → `vim.schedule` → blocking `vim.fn.systemlist` → another command.
   Look for: dropped callbacks, double-fire, stale closures over loop variables,
   use of a detached client after `:checktime`/`tcd`/resession-load changes context,
   missing `vim.schedule` around UI calls, ordering assumptions.
3. **vim.NIL/nil/malformed-response robustness.** `present()`, `fmt_val()`,
   envelope parsing, `(result and result.ok == true)` guards. Feed the client a
   malformed server response mentally: missing `value`, `value` as a non-table,
   `commands` without `args`, `args` entries with unknown `kind`, `values` absent
   for `vocab`, etc. Does any path throw into a callback and kill the flow?
4. **`apply_and_reload` / `:checktime` semantics.** Unsaved-buffer clobber risk,
   race between the engine's write and the reload, effects that CREATE a file
   (palette `note.create` goes through `apply_and_reload` — does it open the new
   note? `:LociNote` does. Drift?), `checktime` on a buffer that doesn't exist.
5. **`vim.lsp.commands` interception.** Which write commands are intercepted
   (apply-then-reload) vs sent as raw `executeCommand`? Any double-fire (client
   runs the handler AND the server executes the command)? Any code action whose
   command is intercepted but whose argument shape doesn't match `arguments[1]`?
6. **Path handling.** `fnameescape` usage, the `relativize` prefix-compare
   (`p:sub(1, #root + 1) == (root .. "/")`), `content_path` → `<root>/.loci/content/...`
   concatenation, `open_linked` → `<root>/...`. Traversal via `..`/absolute paths,
   symlinked vaults, roots with trailing slashes, unicode/space-containing paths.
7. **Palette arg prompting** (`prompt_args`). The recursion's abort semantics per
   kind: required-cancel silently aborts (never calls `done` — intended?), optional
   cancel omits the arg, empty-string vs nil handling, `bool` cancel vs false,
   `vocab` with empty `values`, `list` CSV parsing. Does the client prompt EXACTLY
   what the server's live spec declares?
8. **`pick()` / Snacks compatibility.** `Snacks.picker.pick` call shape,
   `layout = { hidden = { "preview" } }`, `confirm` signature, the pcall fallback
   to `vim.ui.select` — is the fallback shape right? `items` with no `file` key.
9. **Attach logic.** `vault_root` via `vim.fs.find(".loci", upward)` — nested
   vaults, `.loci` as a FILE, buffers with empty names (`BufNewFile`), cwd fallback,
   dedup claim, the `executable("loci-lsp") == 0` one-time-warn path (does
   `notify_once` actually fire?), autocommand timing on `BufReadPost`/`BufNewFile`.
10. **`apply_editor_state`.** `tcd` scoping (tab vs window vs global), partial
    application when a mid-list plugin errors, `pcall(vim.cmd.tcd, ...)` argument
    passing, the resession/wayfinder/haunt API calls (commit history shows these
    were recently fixed — verify they're now right, and that the fix didn't break
    the pcall guard shape).
11. **`M.activate` git observation.** What working directory does
    `vim.fn.systemlist({ "git", ... })` run in after `tcd` + resession load? Is the
    branch observed the right one? Is the blocking call acceptable mid-async-flow?
    Is the `set_editor_state` writeback racy with the engine's own state?
12. **LSP hygiene.** No `on_error`/restart handling, no `on_exit` cleanup, request
    timeout `0` (no timeout), behavior when the server process dies mid-session,
    behavior when the client detaches while a callback chain is in flight.
13. **Nix.** `flake.nix` re-exports from a PRIVATE repo over `git+ssh` (pinned rev —
    reproducibility fine, but check the `inputs.nixpkgs.follows`), `systems =
    ["x86_64-linux"]` only, the `fileset` filter (does `../lua` capture the right
    tree? any symlink/broken-symlink hazard), the version string
    `0-unstable-2026-06-25` (stale? monotonic?), whether `checks.loci-lsp-tests`
    actually resolves (try `nix flake check` if network allows).
14. **Docs-vs-code drift.** README says "eight commands" — count them. README says
    completion/diagnostics/code actions are free — verify the client truly does no
    wiring. Every doc claim about behavior should match `init.lua`.

## 5. Verification steps (use as many as you can)

1. Read `lua/loci/init.lua` fully, at least twice: once for structure, once line-by-line.
2. Read `flake.nix`, `nix/loci-nvim.nix`, `AGENTS.md`, all of `docs/`.
3. Read the engine at `/home/andrew/Documents/Projects/loci-core` to cross-check the
   wire contract: find the `loci/op` handler, the execute-command handler, the
   `loci/commands` implementation, the code-action command IDs, and the envelope
   construction. Report ANY mismatch with the client's assumptions.
4. If the environment allows: `cd /home/andrew/Documents/Projects/loci.nvim && nix flake check`.
5. If a working `nvim` + `loci-lsp` exist, smoke-test headless: attach to a vault
   buffer, run `:LociPalette`, `:LociStatus`, `:LociDoctor`, a code action with
   dry-run preview. Watch for hangs, double pickers, wrong-vault paths.
6. Optionally run `luacheck`/`lua-language-server` if available.

## 6. Deliverable — findings report

Write it to a markdown file and also summarize inline. Structure:

```
# Adversarial review: loci.nvim

## Verdict (1 paragraph)
## Top 5 things to fix first (numbered, with severity)
## Findings
For each finding:
  - ID + severity (CRITICAL / HIGH / MEDIUM / LOW / NIT)
  - Title
  - Location (file:line)
  - Description + impact (who gets hurt, how bad)
  - Evidence (code quote or repro steps)
  - Suggested fix (one or two lines; you do NOT apply it)
## Confirmed-correct areas (what you checked and found sound — builds trust)
## Could-not-verify list (things you lacked evidence/environment to check)
```

Severity rubric: CRITICAL = data loss/corruption or cross-vault contamination;
HIGH = crash/hang or wrong behavior in a normal flow; MEDIUM = wrong behavior in an
edge case or silent degradation; LOW = cosmetic/UX; NIT = style/comment claims.

Do not pad the report. Every finding earns its place; if you investigated something
and it's fine, put it in "Confirmed-correct areas" with a one-line why.
