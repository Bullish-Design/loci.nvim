# 02 — Plan: dependency-ordered realignment work

Ground rules honored: **analysis first**; no `lua/loci/init.lua` or test edits in this pass.
Each item: what changes · why (arch/decision citation) · what breaks if skipped · verification.
Ordering maximizes "buildable + testable as early as possible."

**Key:** P0 = make it build again (the gate). P1 = make it attach and not lie.
P2 = rebuild the user surface on V2 features. P3 = adopt new capabilities.
P4 = tests + docs. All P0–P1 items are prerequisites of everything after.

---

## P0 — Restore the build edge (the lock-update time bomb)

### P0.1 Decide LSP-server ownership (gate — see 03-OPEN-QUESTIONS Q1)
- **What:** The author picks Option 1a (loci-core pygls host) or 1b (dependency-free transport) — *not* this repo's call alone; the server is a loci-core artifact (AGENTS.md D1-a).
- **Why:** `flake.nix:46` (`loci-core.packages.${system}.loci-lsp`) eval-fails the moment the lock moves to V2 (00-KICKOFF §A). No client work is meaningful until a host exists.
- **Breaks if skipped:** `nix flake update loci-core` → eval failure; the fleet (nix-nvim) gets nothing.
- **Verify:** `nix build .#loci-lsp` against the current engine succeeds; `loci-lsp` runs and answers `initialize` with the adapter's capabilities.

### P0.2 (engine, Option 1) Regrow the server entry point in loci-core
- **What:** `apps/lsp/` gains a transport host (pygls 2.1.1 — the pre-V2 pin — or the ~150-line stdio loop from 1b) wrapping `adapter.LociLspServer`; `[project.scripts]` restores `loci-lsp` (and `loci = "apps.cli.main:main"`); the flake re-exports `packages.<sys>.loci-lsp` + `checks`.
- **Why:** adapter docstring "A pygls host wraps these handlers"; guide Phase 13 (LSP/overlays); §3 cost table in 01-ANALYSIS.
- **Verify:** `nix build .#loci-lsp`; `loci-lsp` over stdio answers `initialize`/`did_open`/`diagnostics`; pytest gate (restored) green.

### P0.3 Re-pin loci.nvim's lock to the V2 engine
- **What:** `nix flake update loci-core` (or pin to the refactor branch rev). Also drop the stale `loci` CLI re-export story (see P0.4).
- **Why:** the whole point of P0.
- **Breaks if skipped:** everything stays green against a dead engine (the t01–t16 trap, 01-ANALYSIS §5).
- **Verify:** `nix build .#loci-lsp` + `.#loci-nvim` + `nix flake check` (with P0.2's restored checks) all green.

### P0.4 (engine) Restore the vault bootstrap path
- **What:** `initialize_vault` (`vault/init.py:25`) is called by **nothing** outside tests (00-KICKOFF, unverified-lead row). Give it a wire/CLI home — the cleanest is a registered feature or a CLI `init` verb (the old `loci repository.init` equivalent).
- **Why:** `docs/README.md` and t20 assume `loci repository.init`; the plugin's attach now faces `VaultNotInitialized` (`kernel.py:85-86`) with no recovery path.
- **Breaks if skipped:** a fresh vault cannot be created by any supported tool; the plugin's onboarding is dead.
- **Verify:** `loci init --vault <dir>` (or equivalent) creates `.loci/vault.toml`; `Loci.open` then succeeds.

---

## P1 — Make the client attach and tell the truth

### P1.1 Rewrite the wire layer
- **What:** Delete `M.read` (`loci/op`, 243–270) and `M.command` (`workspace/executeCommand`, 272–300) as generic channels. Replace with a small typed helper per feature family (documents/relations/workspaces/maintenance/search/graph) that speaks the host's actual methods and the registry's request models (`protocol/registry.py`). Keep the `{ok, value}` envelope handling where the host uses it.
- **Why:** the protocol is gone (§2 table); nothing else can call the new engine.
- **Breaks if skipped:** every command returns an LSP "method not found" error.
- **Verify:** `:lua require("loci").documents_list()` (or equivalent) returns rows against a live host.

### P1.2 Keep attach + vault detection; surface new startup failures
- **What:** Attach stays (walk-up for `.loci/` still finds a V2 vault, arch §6.1) but must handle: (a) `loci-lsp` missing (existing guard, 212–218 — keep), (b) `VaultNotInitialized` (new — the `.loci/` dir exists but no `vault.toml`), (c) `VaultPolicyError` FTS5 (D-045, `kernel.py:96`). The on_error/on_exit hygiene (163–190) is **as-is**, keep.
- **Why:** new failure modes are real (D-045; kernel never initializes).
- **Breaks if skipped:** silent attach failure (the exact trap docs/README warns about).
- **Verify:** t02-style no-client warn + new `VaultNotInitialized`/`VaultPolicyError` notices fire correctly.

### P1.3 Diagnostics: real ranges + a severity filter
- **What:** Rely on pushed diagnostics (adapter `diagnostics` 140–158) but add a filter: drop `unmanaged` (information) by default per arch §13 ("Hosts may filter it out entirely by default"); render `missing_target`/`ambiguous_link`/`degraded_identity`/existing families. Verify `didSave` delivery (adapter's `initialize` advertises `textDocumentSync: 1` with no save flag — 00-KICKOFF understated #1); if nvim does not send `didSave`, the host must advertise it or the plugin must.
- **Why:** D-047: one `unmanaged` info row per unmanaged note opened; without a filter the diagnostic panel drowns. Ranges are real now (D-041) — the "line 0" limitation in docs/README is obsolete.
- **Breaks if skipped:** wall of informational `unmanaged` rows; stale-buffer diagnostics.
- **Verify:** opening an unmanaged note shows zero `unmanaged` rows; a broken link shows `missing_target` at the correct line.

### P1.4 Handle `didSave` conflict results
- **What:** When the host answers save with `{committed: false, reason}` (D-041), surface it (`notify` with the reason) instead of assuming success. Today the plugin never reads the save result.
- **Why:** `did_save` CASes against the `did_open` hash; a concurrent external edit or `unchanged` returns `committed:false` (`adapter.py:89-129`).
- **Breaks if skipped:** silent data-overwrite confusion on conflict.
- **Verify:** external edit between open and save → user sees the conflict reason.

---

## P2 — Rebuild the user surface on V2 features

Ordered so each step replaces a dead surface with a live one; the file stays coherent at every point.

### P2.1 Note creation: `documents/create` (+ client-side daily/scratch templates)
- **What:** `M.new_note` (1112–1145), `M.daily` (1086–1099), `M.scratch` (1100–1110) become calls to `documents/create` with validated `name`/`kind`/`body` (D-028 name rules; §11.2 "daily and scratch become document-creation templates"). Open the created document at its **real vault-relative path** — `open_content`'s `.loci/content/` jail join (96–110) is deleted (§6.1); `open_linked` (113–118) generalizes to all paths.
- **Why:** those effects don't exist; the jail doesn't exist.
- **Breaks if skipped:** note creation errors ("unknown command") and opens non-existent jailed paths.
- **Verify:** `:LociNote`, `:LociDaily`, `:LociScratch` create + open; a name with `/` is refused with the engine's typed reason.

### P2.2 Projects browser: `documents/list` filtered by kind
- **What:** `M.projects` (1015–1029) reads `documents/list` and filters `kind == <manifest kind_property value "project">` (§11.2: a project is a document whose mapped kind is `project`); open the real path.
- **Why:** `project.index` gone; no project entity apart from documents (§11.2/§18).
- **Breaks if skipped:** dead read.
- **Verify:** project rows open the right files.

### P2.3 Workspace switcher + CRUD: `workspaces/list|get|put|archive`
- **What:** `M.workspaces` (997–1013) lists via `workspaces/list`; activation is **removed** (no `loci.workspace.activate`). Add `workspaces/put` (create/update) and `workspaces/archive` (typed sugar, D-029). `M.activate` (520–577) and its `editor_state` applier (384–430) and git writeback (549–576) are **deleted** — see P2.6.
- **Why:** arch §6.7 ("no shared `current`…") and §11.2 ("editor-state and global activation operations leave core"); §4.3 host state.
- **Breaks if skipped:** the switcher stays dead; archived-state confusion (D-029 composition).
- **Verify:** list/put/archive round-trip; archiving preserves composition (view keeps documents/files after archive).

### P2.4 Status hub: `workspaces/get` + `documents/list` + `maintenance/refresh`
- **What:** `M.status` (880–995) rebuilds on `workspaces/get` (`WorkspaceView.documents` (ref, role, resource_id, state, current_path) + `.files` (path, role)), `documents/list`, and `maintenance/refresh`. Drop `workspace.current/summary`, `knowledge.objects`, "reconcile" (→ `maintenance/refresh`), "deactivate" (§18, arch §6.7).
- **Why:** those reads are gone; the WorkspaceView is the V2 truth (01-ANALYSIS §6.10).
- **Breaks if skipped:** status hub returns only errors.
- **Verify:** a workspace with files/documents renders them; refresh reports a real `changed_sources` count.

### P2.5 Code actions: dispatch on `action_id`, apply via `execute_action`
- **What:** The `vim.lsp.commands` interception table (566–583, `loci.note.update`/`adopt`/`knowledge.*`/`linked_files.unlink`) is replaced by a dispatcher over `data.action_id` (`documents.adopt`, `documents.format_owned`, `documents.set_status` — `adapter.py:179-196`). Apply-then-reload survives (`apply_and_reload` mechanics). Handle `expected_hash` (CAS base) and `set_status` refusals (D-027 → show the typed reason). `loci.pick_tags` (585–609) is **deleted** (no tags writer, §18); `loci.pick_project` (610–637) becomes `relations/add_project`; `loci.pick_workspace` (639–663) and `loci.link_file` (665–706) become `workspaces/put` file/docs entries.
- **Why:** actions no longer carry `.command` (01-ANALYSIS §2); the effect verbs are gone.
- **Breaks if skipped:** `<localleader>a` dispatches nothing; tags flow silently corrupts (would have been refused).
- **Verify:** a code action on an unmanaged note offers adopt; set_status with `no` shows the refusal.

### P2.6 Activation/editor-state block: delete (or re-home as a *new* plugin-owned feature)
- **What (recommended): delete.** `M.activate`, `deactivate` (340–381), `apply_editor_state` (384–430), git writeback (549–576), `loci.start-work` handling (806–829) — all go. The tab marker `vim.t.loci_workspace_id` and its consumers in nix-nvim's statusline must be removed or made purely local.
- **Why:** arch §6.7/§4.3 put session state in the host *by design*; §18 deletes the engine machinery. The plugin only ever *applied plans the engine returned*; there is no plan anymore. Re-homing activation means writing new product logic (mapping workspace→editor state) that no engine supports — deliberately out of scope for a realignment (03-OPEN-QUESTIONS Q4).
- **Breaks if skipped:** dead commands + a statusline field that can never be set.
- **Verify:** `:LociPalette`-equivalent surface contains no activate/deactivate; statusline compiles without `vim.t.loci_workspace_id`.

### P2.7 Palette and doctor: delete; add graph/health hubs (P3)
- **What:** `M.palette` + `loci/commands` + `prompt_args` (708–775, 831–878) and `M.doctor` + `doctor_fix` (1031–1071) are deleted. Their replacements are P3.1 (vault health via graph + diagnostics) and optionally a registry-derived palette (Q5).
- **Why:** no palette surface (§11.2); no whole-vault doctor (§18).
- **Breaks if skipped:** dead reads.

---

## P3 — Adopt new capabilities

### P3.1 Vault-health hub (replaces doctor)
- **What:** `graph/broken_links`, `graph/missing_attachments`, `graph/ambiguous_links`, `graph/orphans` + `maintenance/refresh`'s `diagnostics_summary` as a picker (the old doctor hub's shape, `adapter`-free). Open findings at real paths.
- **Why:** D-047 emits exactly these families; arch §13 says diagnostics are compiler output. This is the V2-native replacement for the deleted doctor.
- **Breaks if skipped:** no health surface at all.
- **Verify:** a vault with a broken link shows it; fixing the link clears it on refresh.

### P3.2 Search + graph views
- **What:** a `search/text` picker (FTS5, D-045-gated) and optional `graph/backlinks`/`neighbors` per-note view.
- **Why:** capabilities the old client never had (01-ANALYSIS §6.5–6.6).
- **Verify:** text query returns managed+unmanaged rows with state + snippet.

### P3.3 Consistency/staleness surfacing
- **What:** show the returned consistency mode + revision somewhere cheap (statusline segment or notify on query); the CLI's honesty pattern (arch §10.2) applied to the client.
- **Why:** every V2 result names mode+revision; hiding it recreates the silent-staleness the arch explicitly forbids.
- **Verify:** a stale `indexed` read is visibly stale.

---

## P4 — Tests and docs

### P4.1 Rewrite `fakeservers/` to the V2 wire
- **What:** The six fakes (01-ANALYSIS §5) become hosts for the adapter's own methods (`didOpen/didChange/didSave/didClose/diagnostics/code_actions/execute_action`) — best case, they *import* `loci_core.apps.lsp.adapter` over a fake `Loci` so the Lua tests exercise the real V2 logic. Delete the `loci/op` / `executeCommand` / `loci/commands` shapes.
- **Why:** the old fakes encode a dead protocol and make t01–t16/t19 **dead-but-green** (the dangerous class).
- **Verify:** every fake's scenario shape matches an adapter method; no `loci/op` string remains.

### P4.2 Rewrite/delete the 23 tests
- **What:** Keep: t02 (no-client), t03 (latency), t16 (server-death), and the checktime/warning mechanics. Rewrite: note-creation (t08-style → `documents/create`), workspace CRUD, code-action dispatch (t19 → `action_id`), diagnostics filter, `didSave` conflict. Delete: activation/deactivation/palette/tags/doctor/git-writeback tests (t09–t15, t18) and the real-server tests until P0.2 ships a V2 host (t17/t20/t21 return then). Re-point the flake `checks.loci-nvim-tests` at the new suite.
- **Why:** 01-ANALYSIS §5; several tests only pass because they assert against fakes.
- **Verify:** suite green against the V2 host; a grep for `loci/op`/`loci.workspace.activate`/`note.daily` in `.scratch/tests` returns nothing.

### P4.3 Docs rewrite
- **What:** Rewrite per 01-ANALYSIS §4: docs/README (drop activation, jail, completion, doctor, reconcile, `repository.init`, the `loci-lsp`/`loci` install lines pending P0), state-ownership (delete the engine-owned active pointer; keep sole-writer), workspace-lifecycle (workspaces/list|put|archive + refresh; no activation), obsidian-symlink (no content jail), troubleshooting (doctor/reconcile rows → graph-health hub + refresh), AGENTS.md (flake re-export + test-gate claims).
- **Why:** every one of these files now teaches the user a protocol that does not exist.
- **Verify:** no doc mentions `.loci/content`, `doctor`, `reconcile`, `repository.init`, `start-work`, or activation.

### P4.4 Final gate
- **What:** `nix flake check` (with restored loci-core checks) + the rewritten Lua suite + a real-vault smoke.
- **Verify:** all green on the V2 pin, with the pinned rev committed.

---

## Dependency order (one line)

P0.1 (decision) → P0.2/P0.3/P0.4 (buildable again) → P1.1–P1.4 (attach + truth) →
P2.1–P2.7 (live surface) → P3.1–P3.3 (new capabilities) → P4.1–P4.4 (tests/docs/gate).

**Earliest testable state:** after P0.2+P0.3, `nix build .#loci-lsp .#loci-nvim` + a live-host
`initialize` smoke — the repo is buildable and attachable before any client rewrite lands.
