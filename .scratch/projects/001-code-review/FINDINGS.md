# Adversarial review: loci.nvim

> **Fix status (2026-08-03):** seven follow-up changes implemented and verified headlessly on nvim 0.12.3
> (before/after, plus regressions):
> - **F1 (root anchoring) — FIXED.** `root_dir(bufnr)` now resolves the current buffer's client instead of
>   the first-attached one; `link_file_flow` warns + aborts when the current buffer isn't in a vault.
> - **F3 (client pinning) — FIXED, then hardened for resession.** Every user-facing flow captures its entry
>   buffer and threads it through all reads/effects/opens (`M.read`/`M.command`/`apply_and_reload`/`open_*`
>   take an optional pin; the `vim.lsp.commands` handlers pin to `ctx.bufnr` from nvim 0.12's
>   `client:exec_cmd`). Verified: a mid-flow vault switch no longer redirects opens/effects to the wrong
>   vault. **Resession hardening:** the bufnr-pin was verified (with real resession.nvim v1.2.0) to break the
>   activation writeback — `resession.load` wipes every buffer for a global-scoped session (the
>   `<leader>qS` danger path) and detaches every buffer from its client even for a tab-scoped one (attach
>   churn under `eventignore=all`). Fix: `M.activate` pins the **client object** (survives both) via a new
>   polymorphic `resolve_client` in `M.read`/`M.command`; `apply_and_reload` handles a client-object pin.
>   Verified: `set_editor_state` now reaches the right vault's server for BOTH session flavors.
> - **F2 (deactivate) — FIXED** (with F4 + F8). New `deactivate()` flow: runs the effect with NO args (the
>   op clears the Current pointer — the old `workspace_id` arg made the strict request model return
>   `validation_failed`, so the status-hub row never worked), then applies the `DeactivationPlan`: saves the
>   outgoing workspace's resession session + wayfinder trail when the plan says so — guarded so a wrong tab /
>   wrong trail is never clobbered (`resession.get_current()` / `wayfinder.trail_active_name()` must match the
>   workspace's derived handles) — clears `vim.t.loci_workspace_id`, reloads. Both the status hub and the
>   palette route through it. Verified headless with real resession v1.2.0 + wayfinder v0.3.0: happy path
>   saves both + clears the marker; wrong-tab guard skips the saves; the command reaches the server accepted.
> - **F6 (first-activation git observation) — FIXED** (also closes F10). The writeback now resolves the
>   worktree EXPLICITLY — the recorded `worktree_path`, else the vault root — instead of the current tab dir
>   (which on a first activation is just wherever nvim was launched: it silently skipped the writeback or
>   recorded an unrelated repo's branch). Uses non-blocking `vim.system` with `git -C` (the old `systemlist`
>   froze the editor). Verified: launch dir not a repo → still records vault root's branch; a recorded
>   worktree wins over the tab dir.
> - **Global-session landmine — FIXED.** `apply_editor_state` now calls `resession.load(name, {silence_errors,
>   reset = false})` — forcing `reset=false` turns a mis-saved GLOBAL `loci-*` session (the `<leader>qS`
>   danger path) from a wipe-every-buffer into a safe restore (no-op for the designed tab-scoped case), and
>   warns once when the session file is global-scoped. Verified before/after with a real global session:
>   pre-fix the user's buffer was wiped (`valid=false`); post-fix it survives + the warning fires.
> - **F7 (remaining), F9, F11, F12 — FIXED; NITs — FIXED.** F7: `apply_and_reload` now warns when the
>   effect's target buffer is still modified after `:checktime` (a later `:w` would clobber the engine's
>   write). F9: `attach()` registers `on_error`/`on_exit` (scheduled) — server errors surface, an abnormal
>   exit drops the stale `vim.t.loci_workspace_id` + shows a recovery hint (silent on normal quits); the
>   request timeout stays 0 (a local engine may scan a whole vault — false timeouts would be worse). F11:
>   `open_content`/`open_linked`/`link_file_flow` reject absolute/`..`/backslash paths before opening or
>   sending (defense-in-depth under a trusted server). F12: `prompt_args` now notifies on a required-arg
>   cancel instead of aborting silently, and an empty-`values` vocab omits the arg (never opens an empty
>   picker). NITs: version bumped to `0-unstable-2026-08-03`, `relativize` handles trailing-slash roots,
>   `fmt_val` renders nested tables instead of `table: 0x…`. All verified headless (F7 warning fires on a
>   modified buffer; F9 marker cleared on kill + silent on graceful stop; F12 abort notify + empty-vocab
>   omission; F11 path rejection exercised via the safe-join).
>
> **Follow-up pass (2026-08-03):** the last open finding (F5) is closed and the verification suite is banked
> into the repo; three follow-ups documented:
> - **F5 (palette note-creation opens the note) — FIXED.** `run_palette` now opens the created note for the
>   note-creating verbs (`note.create`/`note.daily`/`note.scratch` — response `content_path`, via the same
>   `open_new_note` the direct verbs use) and for `loci.start-work` (response `primary_content_path`). The
>   open happens AFTER the reload / `apply_editor_state` — and the pin is the CLIENT OBJECT captured at
>   palette entry, because start-work's `apply_editor_state` runs `resession.load`, which detaches every
>   buffer from its client (re-resolving by bufnr afterwards finds no client at all — verified during the
>   fix). `root_dir`/`open_content`/`open_linked`/`M.activate` now accept a client object like
>   `resolve_client`. Verified red→green headless (`t08`/`t09` fail on the pre-fix client, pass after).
> - **Regression harness — banked.** The ephemeral `/tmp/loci-review` harness was ported to
>   `.scratch/tests/` (`run-tests.sh` + fakeservers + fixture vaults; resession.nvim v1.2.0 vendored; real
>   `loci-lsp` used by one end-to-end F9 test). Hermetic: fresh sandbox per test (no stray `.loci` marker
>   dirs / sessions between tests), 20 checks green covering F1/F2/F3/F4/F6/F7/F8/F9/F12, the session
>   landmine, single-vault + no-client regressions, and the F5 tests. Runner exits non-zero on any failure.
> - **(3a) Attach-latency UX — FIXED.** `M.read`/`M.command` distinguish "no client" from "client still
>   initializing" (`vim.lsp.get_clients({ name, _uninitialized = true })`, filtered to genuinely
>   uninitialized clients) and notify "server still starting (~4s on first launch)" instead of "open a file
>   inside a loci vault". Covered headless (`t03`).
> - **(3b) Fleet `<leader>qS` guard — FIXED in nix-nvim** (`fix(sessions): <leader>qS saves tab-scoped on a
>   loci tab`, 9fd5049). The generic `resession.save()` writes the GLOBAL flavor; on a loci tab it overwrote
>   the workspace's `loci-<id>.json` as global-scoped. The fleet keymap now checks `vim.t.loci_workspace_id`
>   and saves `resession.save_tab("loci-<id>")` on a loci tab (else the previous behavior). Verified headless
>   with real resession v1.2.0: loci tab → tab-scoped `loci-<id>`; the generic global save writes a separate
>   file and never touches the loci session. The client-side `reset=false` + warning mitigation remains as
>   defense-in-depth. See [the note below](#fleet-leaderqsg-guard) and `docs/troubleshooting.md`.
> - **(3c) loci-core pin drift — RESOLVED.** The bump was blocked because loci-core at `5cdf2ca` did not wire
>   `knappy.wikilinks` into its flake test env (`ModuleNotFoundError` in the re-exported gate). Fixed
>   upstream (loci-core `d967126`: knappy input bumped to the wikilink surface + its pyyaml dep), pin bumped
>   to `d967126`, `nix flake check` green — the client is now gated against the exact engine it was verified
>   against.
> - **(3d) `nix flake check` — GREEN**, now with THREE gates: the re-exported loci-core pytest suite, the new
>   headless CLIENT regression suite (`loci-nvim-tests` check running `.scratch/tests/run-tests.sh` with the
>   flake's own nvim 0.12.3 + the pinned `loci-lsp`, all 20 checks), and the package builds. The harness was
>   hardened along the way: per-test orphan cleanup, and the `loci-lsp` shim now uses a RESOLVED bash
>   shebang (the nix sandbox has no `/usr/bin/env` — glibc execvp silently fell through to the real server,
>   which is how the sandbox-only t16 failure was found).

**Reviewer scope:** `lua/loci/init.lua` (883 lines), `flake.nix`, `nix/loci-nvim.nix`, `docs/*`, plus the
engine at `loci-core` (`lsp/loci_lsp/*.py`, `src/loci_core/{control,domain,ops,requests}.py`) for wire-contract
cross-checking. Verification was READ-ONLY: no repo modifications, no destructive commands.

**Method:** line-by-line read of the client (twice); full read of the server (`server.py`, `translate.py`,
`orchestrate.py`, `editor_state.py`, request/result models); a **live protocol smoke test** — drove the
installed `loci-lsp` over stdio with a JSON-RPC client against a throwaway `/tmp` vault (verified the palette
spec, envelope shapes, `workspace.deactivate` rejection, activation plan, `doctor_fix` apply, note results);
**empirical Neovim checks** against the store's nvim 0.12.3 binary (`systemlist` cwd semantics,
`vim.lsp.start` dedup, `vim.lsp.commands` dispatch, `get_clients` ordering, `vim.cmd.edit` escaping);
`nix flake check` (all checks passed, including the re-exported pytest gate); `lua-language-server` (no
real diagnostics beyond false-positive `vim` globals).

---

## Verdict (1 paragraph)

This is a genuinely thin client that mostly honors its own architecture claims: the sole-writer model is
real (the client never authors frontmatter), the wire contract matches the server on every surface I could
exercise live, `vim.lsp.start` dedup, `systemlist` cwd semantics, `:checktime` clobber protection, and the
activation plugin calls all verified sound. But the client has **one design-level cross-vault hazard and one
confirmed broken user-visible verb**: every path that resolves a file for opening uses `root_dir()` = the
FIRST `loci` client by name rather than the current buffer's client, so with two vaults open the status/
doctor/projects/quick-note hubs open files in the wrong vault (opening a wrong-but-existing note is a
cross-vault data-integrity hit); and the status hub's "deactivate workspace" row always fails with a
`validation_failed` envelope because it passes `workspace_id` to a request model that forbids it (confirmed
live against the server — the palette path works, the documented status-hub path is broken). Around those,
there is a family of async-chain late-binding races (each step re-resolves the client via the current buffer)
that can route a write to the wrong vault if the user switches buffers mid-flow, plus several smaller
behavior gaps (palette note-creation doesn't open the created note, the deactivate save-plan is ignored,
first-activation git observation records whatever repo the tab is in, not the worktree). Not one of these
requires a hostile server; they are ordinary two-vault or first-activation flows.

---

## Top 5 things to fix first

1. **CRITICAL — `root_dir()` has no buffer anchor** (`init.lua:52`). With ≥2 vaults open, `open_content` /
   `open_linked` / `link_file_flow` resolve against the first-attached client's root, not the current
   buffer's. A status-hub note row can open the *same content_path in the wrong vault* — editing the wrong
   file is cross-vault contamination. Fix: derive the root from `client_for(0)` (or pass the client through).
2. **HIGH — Status-hub "▸ deactivate workspace" always fails** (`init.lua:707`). `workspace.deactivate`'s
   request model takes *no* fields (`WorkspaceDeactivateRequest`, strict `extra="forbid"`); the hub sends
   `{workspace_id = wid}` → `validation_failed` (verified live). Fix: drop the arg (the op deactivates the
   Current pointer).
3. **HIGH — Effects re-resolve the client at each async hop** (`M.read`/`M.command` → `client_for(0)`,
   `init.lua:166–210`, used from every chain in the file). Switching vault buffers between a read and a
   picker confirm routes the apply to the wrong vault. Fix: capture the client (or bufnr) at flow start and
   pin it through the chain.
4. **MEDIUM — Deactivation save-policy is discarded.** `workspace.deactivate` returns
   `DeactivationPlan{save_session, save_wayfinder}` (engine default `True`); `apply_and_reload` throws the
   value away, so resession/wayfinder state is never saved on deactivate. Fix: act on the plan (save
   session/trail) before finishing the flow.
5. **MEDIUM — Palette `note.create/daily/scratch` and `start-work` never open the created note**
   (`run_palette` → `apply_and_reload`, `init.lua:552–567`), while `:LociNote`/`:LociDaily`/`:LociScratch`
   do (`open_new_note`, `init.lua:814–836`). Silent creation with no feedback, and a doc/UX inconsistency.
   Fix: route palette note-creating effects through the open path too (and surface `primary_content_path`).

---

## Findings

### F1 — CRITICAL — `root_dir()` resolves the first client by name, not the current buffer's vault

- **Location:** `lua/loci/init.lua:52–55` (`root_dir`), used by `open_content` (62), `open_linked` (70),
  and `link_file_flow` (599–632); reached from the status hub (663, 673, 682), projects hub (762), doctor
  hub (796), and the quick-note verbs (816).
- **Description:** `root_dir()` does `vim.lsp.get_clients({ name = LSP_NAME })[1]` — no `bufnr` filter — so
  with two vaults open it returns the **first-attached** client's root. Every `open_*` then concatenates
  `<wrong root>/.loci/content/<content_path>` (or `<wrong root>/<path>` for linked files) and `:edit`s it.
- **Evidence:** Empirically verified on nvim 0.12.3 with two live clients — `get_clients({name})[1]` returns
  the client created first, regardless of the current buffer, while `client_for(0)` correctly returns the
  current buffer's client. Concretely: vault A attached first, user works in vault B; `:LociStatus` reads
  B's data (via `client_for(0)`, correct) then `open_content("daily/2026-08-03.md")` opens
  `<vaultA>/.loci/content/daily/2026-08-03.md`. If A also has that file, the user is now editing **vault A's
  daily note believing it is B's** — cross-vault contamination (data written into the wrong repo's sidecar).
  If A lacks the file, the user gets an E484 error and the flow silently fails.
- **Impact:** Wrong file opened / wrong vault edited; cross-vault data contamination (CRITICAL per rubric).
- **Suggested fix:** `root_dir()` should take the bufnr (or better, derive the root from the same client
  `client_for(bufnr)` returns), or `open_*` should receive the client/root captured from the read that
  produced the `content_path`.

### F2 — HIGH — Status-hub "▸ deactivate workspace" always fails (validation_failed)

- **Location:** `lua/loci/init.lua:707` (`apply_and_reload("loci.workspace.deactivate", { workspace_id = wid })`).
- **Description:** `WorkspaceDeactivateRequest` has **no fields** ("Deactivates whatever workspace the
  Current pointer names (no inputs)") and the base request is strict `extra="forbid"`. Passing
  `workspace_id` makes pydantic reject the request → the server returns `{ok:false, error:{kind:
  "validation_failed", ...}}`, and the client's `M.command` error path notifies. The row never works.
- **Evidence:** Verified live over the protocol against the installed `loci-lsp`:
  `deactivate WITH workspace_id → {"error": {"kind": "validation_failed", "message": "1 validation error
  for WorkspaceDeactivateRequest\nworkspace_id\n  Extra inputs are not permitted [type=extra_forbidden...]",
  "ok": false}`; `deactivate WITHOUT args` reaches the engine (`not_found` only because nothing was active).
  The palette path (`loci/commands` advertises `workspace.deactivate` with `args: []`, so `run_palette`
  sends `{}`) works.
- **Impact:** The documented deactivation verb in the docs' own surface (`docs/workspace-lifecycle.md`
  "status hub → ▸ deactivate workspace") always errors — a normal-flow broken behavior.
- **Suggested fix:** `apply_and_reload("loci.workspace.deactivate", {})` (the op needs no id).

### F3 — HIGH — Effects re-resolve the client at every async hop (cross-vault write on mid-flow buffer switch)

- **Location:** `M.read`/`M.command` resolve `client_for(0)` at call time (`init.lua:166–210`); every
  multi-step flow (`preview_then_apply` 276–290, `pick_tags`/`pick_project`/`pick_workspace` 378–449,
  `M.status` 634–731, `M.workspaces` 733, `link_file_flow` 599) re-resolves at each step.
- **Description:** A flow starts on vault B's buffer (read → correct client) but the *apply* step runs later
  (after a picker/input) against `client_for(0)` = whatever the user is on *now*. If the user switches to a
  vault A buffer while the non-modal snacks picker is open, the write goes to A. Because `content_path`s
  are vault-relative and the effect args carry B's paths, the write either hits A's engine (clean
  `not_found`/format error — benign) or, when the same `content_path` exists in A, **writes to A's note**.
- **Impact:** Cross-vault effect routing under a realistic (if racy) interaction; wrong-vault writes when
  paths collide. This is the same root cause family as F1 (client anchoring) and should be fixed together:
  capture the client/bufnr at flow start and pin it.
- **Suggested fix:** `M.read`/`M.command` should accept an explicit client (or bufnr) and the picker flows
  should capture `client_for(0)` once at entry.

### F4 — MEDIUM — Deactivation save-policy (`DeactivationPlan`) is discarded; editor state lost on deactivate

- **Location:** `lua/loci/init.lua:707` (deactivate via `apply_and_reload`, whose callback drops the value);
  engine: `src/loci_core/domain/activation.py` (`SAVE_SESSION_ON_DEACTIVATE = True`,
  `SAVE_WAYFINDER_ON_DEACTIVATE = True`; `DeactivationPlan{save_session, save_wayfinder}`).
- **Description:** The engine's deactivation contract tells the editor what to persist before teardown
  (resession session, wayfinder trail). The client ignores the plan: it never calls resession save or
  wayfinder save on deactivate. Resession/wayfinder auto-save may paper over this in the happy path, but
  the engine's explicit plan is dead code client-side.
- **Impact:** Workspace editor state can be lost on deactivate; the design's save-policy seam is not wired.
- **Suggested fix:** Have the deactivate flow read `value.save_session`/`value.save_wayfinder` and save
  accordingly (pcall-guarded like `apply_editor_state`).

### F5 — MEDIUM — Palette `note.create`/`note.daily`/`note.scratch`/`start-work` create files without opening them

- **Location:** `lua/loci/init.lua:552–567` (`run_palette` → `apply_and_reload` for everything except
  activate/start-work; the note-creating effects discard the returned `content_path`).
- **Description:** `:LociDaily`/`:LociScratch`/`:LociNote` explicitly open the created note
  (`open_new_note`, 814–836), but the palette's `note.create`/`note.daily`/`note.scratch` (and
  `start-work`, which ignores `value.primary_content_path`) create the file and never open or surface it.
  The user gets no feedback that a note was created (value discarded).
- **Impact:** UX inconsistency with the documented "create + open" flows (`docs/workspace-lifecycle.md`
  describes start-work as "a note + a workspace + activate"); silent creation from the palette.
- **Suggested fix:** For note-creating palette commands, call `open_new_note(value)` (and open
  `primary_content_path` for `start-work`) after the apply.

### F6 — MEDIUM — First-activation git observation records whatever repo the tab is in, not the workspace worktree

- **Location:** `lua/loci/init.lua:331–350` (`M.activate`); `apply_editor_state` 295–328.
- **Description:** The engine omits `git` from `editor_state` on activate (verified live: plan carries
  `git: {branch: null, worktree_path: null}`), so the editor must observe it. But on the **first**
  activation there is no recorded worktree, so no `:tcd` happens (`present(git.worktree_path)` is false),
  and `vim.fn.systemlist({"git","rev-parse","--abbrev-ref","HEAD"})` runs in the tab-local dir *as it is at
  activation time* — typically nvim's launch dir. If that's not a git repo, `shell_error != 0` and the
  writeback is **silently skipped** (the workspace never gains a worktree, forever). If it *is* an
  unrelated repo (e.g., nvim launched from the nix-nvim checkout), the wrong branch + that repo's path are
  recorded as the workspace's git state and used for `:tcd` on every later activation. Additionally,
  `apply_editor_state` runs `:tcd` *before* `resession.load`, so after the session restores, `getcwd()` /
  `systemlist` observe the session's dir, not the worktree. (`systemlist` cwd semantics were verified:
  nvim 0.12 runs it in the tab-local dir — the observation is *of the tab*, not of the recorded worktree.)
- **Impact:** The documented "observe the git branch you actually checked out" feature silently no-ops or
  records wrong metadata that drives future tab cd's.
- **Suggested fix:** When `git.worktree_path` is absent, tcd to the picked workspace's directory first
  (or fall back to `getcwd()` only when it is a git worktree); reorder the tcd after `resession.load`.

### F7 — MEDIUM — `apply_and_reload` runs `:checktime` on the *current* buffer, not the effect's target; stale-write clobber

- **Location:** `lua/loci/init.lua:213–220`.
- **Description:** The effect targets a note via `content_path`, but `:checktime` reloads whatever buffer is
  current. If the target note is open in another window, that buffer stays stale; and if the current buffer
  has unsaved changes, `:checktime` refuses to reload (verified: it warns, does not clobber — the comment's
  claim holds) — but the user can then `:w` the stale buffer and **overwrite the engine's just-written
  change** (e.g., a `note.update` status write silently reverted). Docs acknowledge the unsaved case
  ("save or reload") but not the wrong-buffer case.
- **Impact:** Stale display and a user-driven clobber path; buffer divergence from the engine's intent log.
- **Suggested fix:** `apply_and_reload` should resolve the target note's bufnr (from `content_path`/root) and
  checktime that buffer (all loaded buffers via `:checktime!` on a range, or `checktime` on the target).

### F8 — MEDIUM — `vim.t.loci_workspace_id` never cleared on deactivate (stale statusline)

- **Location:** `lua/loci/init.lua:340` (set in `M.activate`); no clearing counterpart anywhere (deactivate
  flows at 707 / palette).
- **Description:** After deactivating, the tab-local marker keeps the old workspace id; the statusline shows
  `loci:<old-id>` until the next activation. The status hub self-corrects (engine `workspace.current` →
  `found:false`), but any consumer of `vim.t.loci_workspace_id` does not.
- **Suggested fix:** Clear `vim.t.loci_workspace_id` on successful deactivate.

### F9 — LOW — No `on_error`/`on_exit`/restart; request timeout 0; no server-death handling

- **Location:** `lua/loci/init.lua:141` (`vim.lsp.start` without handlers), `166–210` (`timeout 0`).
- **Description:** If `loci-lsp` dies mid-session there is no cleanup, no notify, no reconnect; in-flight
  request callbacks never fire (no timeout) and the hub flows just stop. A fresh buffer event re-spawns via
  dedup only once the dead client is gone.
- **Suggested fix:** Add `on_error`/`on_exit` notify (and optionally a bounded request timeout).

### F10 — LOW — Blocking `systemlist` inside the activate async chain

- **Location:** `lua/loci/init.lua:342`.
- **Description:** `vim.fn.systemlist` is a blocking call inside a `vim.schedule`-deferred callback in the
  middle of the activate chain; on a slow/network worktree the editor freezes (all LSP traffic stalls too).
- **Suggested fix:** Use `vim.system`/`jobstart` with a callback, or move the observation out of the chain.

### F11 — LOW — `open_content`/`open_linked` trust server paths for concatenation

- **Location:** `lua/loci/init.lua:62–76`.
- **Description:** `root .. "/.loci/content/" .. content_path` (and `root .. "/" .. path`) will happily
  produce a traversal (`..`) or absolute target if the server ever returns one. Today the engine validates
  content paths and linked paths (`valid_linked_file_path` rejects abs/`..`), so this is defense-in-depth
  against a trusted server only.
- **Suggested fix:** Validate the joined path stays under the root before `:edit`.

### F12 — LOW — `prompt_args` required-arg cancel aborts silently; vocab-with-empty-values edge

- **Location:** `lua/loci/init.lua:491–550`.
- **Description:** Cancelling a required arg returns without calling `done` and without notifying — the
  command silently dies (the comment says "intended", but the user gets no feedback). `vocab` with empty
  `values` runs `vim.ui.select({})` — behavior is implementation-dependent (some UIs error, some hang).
  No current server spec produces empty `values`, so this is an edge.
- **Suggested fix:** Notify on required-cancel; skip the prompt (and `continue(nil)`) when `values` is empty.

### NIT — version string stale; `relativize` trailing-slash; `fmt_val` table rendering

- `nix/loci-nvim.nix:3` — `version = "0-unstable-2026-06-25"` predates the 2026-07-10 plugin commits; won't
  bump without a manual edit (monotonicity fine, staleness real).
- `lua/loci/init.lua:607–611` — `p:sub(1, #root + 1) == (root .. "/")` never matches for a trailing-slash
  root; `vault_root` never produces one, so NIT.
- `lua/loci/init.lua:222–235` — `fmt_val` renders nested tables in a list as `table: 0x…` in dry-run diffs.

---

## Confirmed-correct areas (verified, not assumed)

- **`vim.lsp.start` dedup** — claim in `init.lua:127` verified empirically: two calls with identical
  (name, cmd, root_dir) configs return the same client id; a different root spawns a new one.
- **`systemlist` cwd semantics** — verified on nvim 0.12.3: it runs in the tab/window-local dir (respects
  `:tcd`/`:lcd`), so the git observation at least runs in the *tab's* dir.
- **`vim.cmd.edit(fnameescape(p))`** — verified opens files with spaces, `#`, `%`, `|` correctly.
- **`client_for(0)`** — verified `get_clients({bufnr=0})` returns the current buffer's client.
- **`:checktime` clobber protection** — the comment's claim holds (modified buffers are not reloaded).
- **Wire contract** — verified live, end to end: palette arg specs (`loci/commands` kinds: string/vocab/
  list/bool, `dry_run` excluded), the `{ok, value, error}` envelope on both `loci/op` and
  `workspace/executeCommand`, `workspace.current`/`summary`/`get`/`index` shapes, `project.index`/`members`,
  `doctor` report (`issues`, `stats.by_code.missing_loci_id`), `note.create/daily/scratch` returning
  `content_path`, the activation plan's `editor_state` (git null until observed, haunt/wayfinder/resession/
  tabby derived), `set_editor_state` accepting a `git` block, `doctor_fix` via executeCommand applying
  (`dry_run=false` — the status-hub fix row works).
- **Code-action argument shapes** — server `_command_action`/`_pick_workspace_action`/`_link_file_action`
  emit `arguments[1]` exactly as the client's intercepted handlers expect.
- **`vim.lsp.commands` interception** — no double-fire by construction: nvim 0.12 dispatches
  `client:exec_cmd` → `lsp.commands[cmd]` handler *instead of* sending executeCommand. (See
  Could-not-verify for the executor dependency.)
- **`apply_editor_state` plugin calls** — resession `load(name, {silence_errors})` / wayfinder
  `trail_load_named` / haunt `change_data_dir` match the pinned plugin APIs per commit 262bbc2.
- **Eight user commands** — `:LociPalette/Status/Workspaces/Projects/Doctor/Daily/Scratch/Note` = 8,
  matching the README's "entire command surface — eight commands".
- **No feature wiring** — the client truly does not call `vim.lsp.completion.enable`, wire diagnostics, or
  bind a code-action keymap (server pushes `loci-doctor` diagnostics; line-0 anchor confirmed server-side).
- **`nix flake check`** — passed, including the re-exported `loci-lsp-tests` pytest/pytest-lsp gate; the
  `loci-lsp` package re-export and `nixpkgs.follows` resolve.
- **fileset filter** — `lib.fileset.toSource { root = ../.; fileset = ../lua; }` captures only `lua/` (no
  `.devenv` symlink hazard); the derived output built cleanly in the check.
- **Palette `workspace.deactivate`** — works (no args); only the status-hub variant (F2) is broken.
- **Local-variable closures** — the status hub's per-row `action` closures capture per-iteration `local cp`
  / `local p` correctly (no stale-loop-variable bug).

---

## Could-not-verify list

All five items below were RESOLVED during the follow-up passes (2026-08-04); they are kept for the record.

- **tiny-code-action@0d040ed dispatch path — VERIFIED (fleet = rachartier/tiny-code-action.nvim@0d040ed,
  wired as `tiny-code-action` with `backend="vim", picker="snacks"`).** `action.lua` calls
  `client:_exec_cmd(command, ctx)` / `client:exec_cmd(command, ctx)` — nvim 0.12.3's `exec_cmd` resolves
  `vim.lsp.commands` FIRST, so the client's write-command interception (apply-then-reload + `:checktime`)
  and all four client-only code-action commands DO dispatch. `ctx.bufnr` is set by `exec_cmd`
  (`_resolve_bufnr(nil)` → current buffer) and the picker restores the original buffer's window before
  exec, so the pin is the invocation buffer. Banked empirically as harness test `t19`.
- **Snacks picker API drift — VERIFIED against the fleet's snacks v2.31.0.** `Snacks.picker.pick(opts)`
  single-table overload with `items` (v2.31.0 `M.pick(source, opts)` + `@overload fun(opts)`), `format`
  returning `{ {text, hl} }`, `confirm(picker, item)`, and `layout.hidden` (a documented
  `("input"|"preview"|"list")[]` field) all match; `Snacks.picker.files({ cwd, confirm })` resolves to
  `pick("files", opts)` over the files source config. The `vim.ui.select` pcall fallback stays as shield.
- **End-to-end nvim + loci-lsp smoke test — DONE (harness `t17` real attach/exit, `t20` real full-stack:
  `repository.init` → `M.daily()` against the real engine writes + opens the created note).**
- **Pinned rev drift — RESOLVED.** loci.nvim's pin now tracks loci-core `d967126` (knappy wired); see the
  follow-up note below.
- **haunt/resession/wayfinder runtime behavior inside a real activation — DONE (harness `t21`): real
  vendored haunt v1.2.0 `change_data_dir` is invoked with the plan's dir and succeeds; real resession
  v1.2.0 load runs; wayfinder stays stubbed to its called surface (its trail backend needs the interactive
  stack — see tests/README.md).**

---

## Follow-ups (2026-08-03)

### Fleet `<leader>qS` guard

**Scope note:** nix-nvim was treated as READ-ONLY in the original task, but the follow-up pass was
authorized to fix it — the fleet keymap is now patched (see below); this section records the hazard + both
mitigations.

- `resession.save()` (the fleet `<leader>qS`) saves the current tab's buffers as a
  **GLOBAL-scoped** session. Run on a loci tab, it overwrites the workspace's
  session file (`loci-<id>.json`) with a global-scoped one — a future activation
  would then `resession.load` a global session, which by resession's design WIPES
  every listed buffer (the "reset" behavior).
- **Client-side mitigation (landed with the F1–F12 pass):** `apply_editor_state`
  calls `resession.load(name, { silence_errors, reset = false })` — `reset=false`
  turns the mis-saved global session into a safe restore (a no-op for the designed
  tab-scoped case), and the client warns once when the session file is
  global-scoped ("re-save it tab-scoped from the workspace tab").
- **Fleet-side fix — DONE (nix-nvim 9fd5049).** The fleet `<leader>qS` binding
  now checks `vim.t.loci_workspace_id` and saves
  `resession.save_tab("loci-<id>")` (tab-scoped) on a loci tab instead of the
  global `resession.save()`; other tabs keep the previous behavior. The
  client-side mitigation remains as defense-in-depth.
- See also `docs/troubleshooting.md` ("Fleet `<leader>qS` on a loci tab").

### loci-core pin drift — RESOLVED (2026-08-04)

The flake pinned `57c83f4`; the local engine was ahead at `5cdf2ca` (stage-3). The bump was blocked by the
re-exported `loci-lsp-tests` check failing at that rev — `ModuleNotFoundError: knappy.wikilinks` — because
loci-core's flake pinned knappy at a rev predating the wikilink surface. Fixed upstream (loci-core
`d967126`): the knappy input now points at the wikilink-bearing rev and the knappy package declares its
1.1.x runtime dep pyyaml. loci.nvim's pin now tracks `d967126` and `nix flake check` is green — the client is
gated against the exact engine its contracts were verified against (envelope, palette spec,
`workspace.deactivate` request model, activation plan / `primary_content_path`).
