# 01 — Analysis: what loci.nvim must become for the current loci-core

All claims cite `file:line`, a command's output, or a reproduction. Engine refs are
to `../loci-core` @ `refactor/blue-sky-v2-findings` (c6cc3a4) unless noted. Plugin refs are
to `lua/loci/init.lua`. The wire surface that exists in the current engine is **24 features**
(see 00-KICKOFF), served by a **transportless adapter class** (`apps/lsp/adapter.py`) and a
**registry-derived CLI** (`apps/cli/main.py`) — and by nothing else.

---

## 1. Capability inventory of loci.nvim

Every user-visible feature, mapped to the current engine. Classifications:
**as-is** (works unchanged) · **port** (rebuild against a V2 feature) · **editor** (host-side,
move into the plugin) · **delete** (engine capability gone; no V2 equivalent).

| # | Feature | Where (init.lua) | Wire surface it needs | V2 verdict | V2 disposition |
|---|---|---|---|---|---|
| 1 | Auto-attach: `BufReadPost`/`BufNewFile` walks up for `.loci/`, `vim.lsp.start{cmd="loci-lsp"}` | 197–226 | `loci-lsp` binary on PATH; `.loci/` dir | **port** | Vault detection survives (V2 root = `.loci/` with `vault.toml`, arch §6.1). But there is **no binary to start** (00-KICKOFF §A) and `Loci.open` raises `VaultNotInitialized` — a new failure mode to surface. |
| 2 | Server-death hygiene: `on_error`/`on_exit`, tab-marker clear, recovery hint | 163–190 | none (client-side) | **as-is** | Survives any host. Keep. |
| 3 | `M.read` — generic `loci/op` read primitive | 243–270 | `loci/op` | **delete** | No `loci/op` in V2 (`adapter.py`). Typed features only. |
| 4 | `M.command` — generic `workspace/executeCommand` effect primitive | 272–300 | `workspace/executeCommand` | **delete** | No command table in V2. Effects are typed features (`documents/…`, `relations/…`, `workspaces/…`). |
| 5 | `apply_and_reload` — effect then `:checktime` (sole-writer discipline) | 302–332 | none | **as-is** | Engine is still the source writer (`executor.write`, arch §12.1); `:checktime` reload remains correct. Keep. |
| 6 | `preview_then_apply` — `dry_run` arg + confirm | 334–358 | `dry_run=true` request arg | **port** | V2 previews are **feature-declared pure routes** (`registry.py` `preview=`, D-032); there is no `dry_run` request arg. Client must call the preview route, then the handler — two calls, or code-action `expected_hash` (adapter `code_actions`). |
| 7 | `deactivate` — `loci.workspace.deactivate` + DeactivationPlan (save resession/wayfinder) + clear `vim.t.loci_workspace_id` | 340–381 | `loci.workspace.deactivate`; plan fields `save_session`/`save_wayfinder` | **delete** | No activation in V2 (arch §6.7; §18). Engine never returns a plan. Session/trail persistence is host-owned (§4.3). |
| 8 | `activate` — `loci.workspace.activate` + `apply_editor_state` (git tcd, haunt data_dir, resession load, wayfinder trail) + tab marker | 384–430, 520–577 | `loci.workspace.activate`; `editor_state` blocks | **delete** | No activation/editor state in V2 (arch §6.7 "Core returns a host-neutral WorkspaceView and never knows plugin names"). |
| 9 | Git branch observation writeback — `loci.workspace.set_editor_state` | 549–576 | `loci.workspace.set_editor_state` | **delete** | No editor state in the engine. If the editor wants a recorded branch, it owns that locally. |
| 10 | `vim.lsp.commands` write interception (`loci.note.update`, `loci.note.adopt`, `loci.knowledge.add/set_primary/remove`, `loci.linked_files.unlink`) → apply-then-reload | 566–583 | code actions carrying `.command` | **port** | V2 actions carry `data.action_id` + `data.expected_hash` (`adapter.py:160-177`), **not** `.command`. Dispatch on `action_id` (`documents.adopt` / `documents.format_owned` / `documents.set_status`), apply via `execute_action` (`adapter.py:179`). |
| 11 | `loci.pick_tags` — `field_values` read → `note.update` tags dry-run | 585–609 | `field_values` read; `loci.note.update`; a `tags` writer | **delete** | No tags writer in V2 (§18 "a `tags` writer in the base kernel"). No `field_values` read. |
| 12 | `loci.pick_project` — `project.index` → `project.link` dry-run | 610–637 | `project.index`, `loci.project.link` | **port** | `relations/add_project` (member ref + project ref; previews the adoption when the member is unmanaged, D-032/§7.3). |
| 13 | `loci.pick_workspace` — `workspace.index` → `loci.<op>` effect | 639–663 | `workspace.index`, `loci.workspace.*` effects | **delete** | No workspace effect commands. `workspaces/put` + `workspaces/archive` are typed features. |
| 14 | `loci.link_file` — role picker → `loci.linked_files.link`; `link_file_flow` (Snacks file pick) | 665–706, 879–928 | `loci.linked_files.link` | **port** | `workspaces/put` `files: [{path, role}]` — roles survive in the manifest (arch §6.7 example). |
| 15 | `M.palette` — `loci/commands` read + per-arg prompting + effect dispatch | 708–775, 831–878 | `loci/commands` | **delete** | No palette surface in V2. (Rebuilding a palette from the **registry's 24 typed features** is a new capability — see §6.) |
| 16 | `prompt_args` — kind-based prompting (`bool`/`vocab`/`list`/`string`) | 708–775 | arg specs from `loci/commands` | **delete** | Dies with the palette. A registry-derived arg prompt is a future option. |
| 17 | `M.status` hub — `workspace.current`/`summary`/`get`, `project.get`/`members`, knowledge objects, linked files, unlink/link/reconcile/deactivate rows | 880–995 | `workspace.current/summary/get`; `project.get/members`; `loci.reconcile`; `loci.workspace.deactivate` | **delete** | `workspace.current`/`summary`, `knowledge.objects`, `reconcile`, `deactivate` all gone. V2 substitutes: `workspaces/get` (WorkspaceView: `documents`+`files`), `documents/list`, `maintenance/refresh`, `graph/*`. |
| 18 | `M.workspaces` switcher — `workspace.index` → `activate` | 997–1013 | `workspace.index`, `loci.workspace.activate` | **port** | `workspaces/list` (+ `workspaces/put`, `workspaces/archive`). No activation step. |
| 19 | `M.projects` browser — `project.index` → `open_content` | 1015–1029 | `project.index`; `.loci/content/` paths | **port** | `documents/list` filtered by kind (arch §11.2 "project CRUD becomes document capabilities filtered by the policy-mapped kind value"); open the **real vault-relative path** (§6.1). |
| 20 | `M.doctor` hub — `doctor` read, `loci.doctor_fix` | 1031–1071 | `doctor` read; `loci.doctor_fix` | **delete** | No whole-vault doctor (§18). Diagnostics are compiler output per source (arch §13); `maintenance/refresh` returns `diagnostics_summary`. |
| 21 | `M.daily` / `M.scratch` — `loci.note.daily`/`loci.note.scratch` → open | 1086–1110 | `loci.note.daily/scratch`; `.loci/content/` | **port** | §11.2: "daily and scratch become document-creation templates." Client-side templates over `documents/create` (validated `name`, `kind`, `body`). |
| 22 | `M.new_note` — `loci/commands` → `note.create` prompted args | 1112–1145 | `loci/commands`; `loci.note.create` | **port** | `documents/create` with validated name (D-028) + `body`. |
| 23 | `open_content` — `<root>/.loci/content/<content_path>` jail join | 96–110 | `content_path` | **delete** | No content jail (arch §6.1). All V2 paths are real vault-relative `VaultPath`s. `open_linked` generalizes to everything. |
| 24 | Completion on frontmatter keys (blink `lsp` source) | — (relies on old server's `completion` handler, `server.py:255`) | `textDocument/completion` | **delete** | V2 adapter has no completion. The doc claim (docs/README "Completion — … completes the key's allowed values") is dead. |
| 25 | Diagnostics rendering (`vim.diagnostic` over `publishDiagnostics`) | — (implicit) | `textDocument/publishDiagnostics` | **as-is + filter** | V2 emits real UTF-16 ranges and **4 families**; `unmanaged` at information (D-047, `adapter.py:148`). Arch §13: "Hosts may filter it out entirely by default." **The plugin has no severity filter — it needs one.** |
| 26 | Code actions via fleet `<localleader>a` | — (implicit) | `textDocument/codeAction` | **port** | Action payload changed: `{title, kind, data:{action_id, path, expected_hash, args}}` (`adapter.py:160-177`). tiny-code-action dispatch must adapt; `expected_hash` enables CAS. |

**Count:** 2 as-is · 9 port · 0 editor (activation/editor-state items classified delete — the engine will never restore them, arch §6.7/§4.3) · 13 delete.

---

## 2. Protocol delta

Every custom method the plugin sends or receives, mapped to V2.

| Method (plugin ⇄ server) | init.lua ref | Old server (pinned rev) | V2 adapter | Disposition |
|---|---|---|---|---|
| `loci/op` `{op, args}` | 258 | `server.py:144` | — | **gone** |
|  — ops: `field_values`, `project.index`, `project.get`, `project.members`, `workspace.index`, `workspace.current`, `workspace.summary`, `workspace.get`, `doctor` | 258, 587–664, 880–1071 | old control surface | — | **all gone** |
| `workspace/executeCommand` `{command, arguments:[args]}` | 284 | pygls built-in | — (adapter has `execute_action`, 179) | **gone** |
|  — commands: `loci.workspace.activate`, `loci.workspace.deactivate`, `loci.workspace.set_editor_state`, `loci.start-work`, `loci.note.create`, `loci.note.daily`, `loci.note.scratch`, `loci.note.update`, `loci.note.adopt`, `loci.knowledge.add`, `loci.knowledge.set_primary`, `loci.knowledge.remove`, `loci.linked_files.link`, `loci.linked_files.unlink`, `loci.project.link`, `loci.reconcile`, `loci.doctor_fix`, `loci.repository.init` | 343–1155 | old control surface | — | **all gone** |
| `loci/commands` (palette read) | 843, 1122 | `server.py:237` | — | **gone** |
| `initialize` | — | `server.py:71` | `adapter.initialize` (65) | **kept** — capabilities differ: no completion; `textDocumentSync: 1`; `diagnosticProvider` present. ⚠️ `didSave` not advertised (see 00-KICKOFF, understated #1). |
| `textDocument/didOpen` | — | `server.py:300` | `adapter.did_open` (73) | **kept** — new semantics: captures the disk hash as the save CAS base. |
| `textDocument/didChange` | — | (old: not a handler) | `adapter.did_change` (82) | **kept (new)** — overlay + line-index invalidation. |
| `textDocument/didSave` | — | `server.py:308` (raw `write_bytes`) | `adapter.did_save` (89) → `{committed, reason/revision}` | **kept but contract changed** — CAS vs the `did_open` hash; `committed:false` on conflict/unchanged. The plugin never reads this result today; it must. |
| `textDocument/didClose` | — | (old: none) | `adapter.did_close` (131) | **kept (new)** |
| `textDocument/publishDiagnostics` (server→client) | — | old doctor findings, line 0 | V2 `diagnostics` (140): real UTF-16 ranges, 4+ families, `unmanaged`→3 | **kept — ranges real now; needs filtering** |
| `textDocument/codeAction` | — | old actions with `.command` | `adapter.code_actions` (160): `{title, kind, data:{action_id, path, expected_hash, args}}` | **changed — hard break** for `vim.lsp.commands` interception (566–583) |
| `workspace/executeCommand`/`execute_action` (new, for actions) | — | — | `adapter.execute_action` (179): `documents.adopt` / `documents.format_owned` / `documents.set_status` | **new** — requires the missing host (§3) |
| `textDocument/completion` | — | `server.py:255` | — | **gone** |
| Envelope `{ok: true, value}` / `{ok: false, error}` | 258, 284 | old envelope | CLI only (`cli/main.py:62-69`); the adapter returns plain results | **changed** — LSP surface of the new host is TBD (§3); the CLI keeps the envelope |

**Wire vocabulary V2 adds that the plugin could speak** (all 24, from `protocol/registry.py`):
`documents/get|list|preview_adoption|adopt|create|format_owned|set_status|move`,
`relations/add_project|remove_project`, `workspaces/put|get|list|archive`, `maintenance/refresh`,
`search/text`, `graph/backlinks|neighbors|project_members|broken_links|missing_attachments|ambiguous_links|orphans|traversal`.

---

## 3. Build / packaging decision (§A)

**The question:** who builds the LSP server now? V2 ships an adapter **class**, not a server; no
`[project.scripts]`; the flake exports only `loci-core` + `default`.

**Options and costs:**

| Option | What | Cost | Fit with the record |
|---|---|---|---|
| **1a. loci-core regrows an `apps/lsp` entry point with pygls** | `buildPythonApplication` over `adapter.py` + a pygls host; flake exports `packages.<sys>.loci-lsp` again; `[project.scripts]` returns (`loci` + `loci-lsp`) | loci-core re-adds pygls 2.1.1 + lsprotocol + cattrs (the exact pins the pre-V2 flake already carried); one more app in loci-core. DAG stays one edge: loci-core → loci.nvim. | The adapter's own docstring: "A **pygls host** wraps these handlers in its own transport." Guide Phase 13 (LSP/overlays) is written for this. pygls is **not** in arch §18's deletion list — the adapter survived the clean-room by design; only its host is absent. |
| **1b. loci-core regrows the entry point with a dependency-free transport** | ~150-line JSON-RPC Content-Length stdio loop over the adapter (the fakeservers' exact shape); zero new deps | Keeps loci-core's pydantic+pyyaml-only stance; but hand-rolls LSP details (shutdown, exit, version negotiation) nvim tolerates leniently. Proven pattern in this repo (`.scratch/tests/fakeservers/*.py`). | Contradicts the adapter docstring's "pygls host" wording, but matches loci-core's dependency discipline better than pygls does. |
| **2. loci.nvim vendors a thin server** | A pygls (or raw) host in loci.nvim importing `loci_core.apps.lsp.adapter` | The plugin derivation is currently **pure Lua** (`nix/loci-nvim.nix`, `src = ../lua`); it would need a Python package + the loci-core package as a runtime dep — breaking the clean-room/D1-a shape (AGENTS.md: "NOT authored here"). Also two repos now own LSP. | Violates the documented ownership; heaviest long-term cost. |
| **3. Drop LSP; drive the CLI** | Plugin shells out to `loci` per action; diagnostics gone (or from an external watcher) | Loses the exact integration arch §13 builds around (overlays, pushed diagnostics, code actions with `expected_hash`). The adapter becomes dead weight. | Rejects the adapter's entire purpose. |

**Recommendation: Option 1a** (pygls host in loci-core, flake re-export restored). It completes
the LSP story the adapter already declares rather than restoring a deleted capability (pygls is
not in §18); it keeps the DAG at one edge so nix-nvim's PATH wiring (`loci-lsp`) is unchanged; and
it is the only option that keeps diagnostics/code-actions/overlays — the features V2's LSP story
is actually about. **1b is the runner-up** if loci-core's maintainers refuse the pygls dep; it
ships the same wire contract. Option 2 and 3 are argued against above.

**Consequence if the decision stalls:** the flake eval failure on the next lock update is
**unavoidable** regardless of option — `flake.nix:46` references `loci-core.packages.<sys>.loci-lsp`
which does not exist today. `02-PLAN.md` item P0.1 treats this as the gate.

---

## 4. Docs delta

| File | Verdict | Statements now false (with refs) |
|---|---|---|
| `docs/README.md` (209 lines) | **wholesale wrong** | "one `loci-lsp` server runs per vault" (attach is fine, binary isn't); "carries a `loci_id` in frontmatter, stored under `<vault>/.loci/content/`" (§6.1 — no jail); activation section ("engine for an editor-state plan… writes it back") (§6.7 — no editor state); "Completion — … completes the key's allowed values" (no completion); "Diagnostics — the engine's `doctor` findings are pushed" (no doctor); Limitations "Diagnostics anchor at line 0" (now real ranges — this "limitation" is **fixed**); "The old 'refresh' is now the engine's `reconcile`" (§18 — no reconcile); `nix build .#loci-lsp` / `uv tool install --from ~/Documents/Projects/loci-core/lsp loci-lsp` (no such package/app); `loci repository.init --vault .` (no such CLI command); `loci start-work "…"` (no such command). |
| `docs/state-ownership.md` (35) | **wholesale wrong** | "active-workspace pointer … lives inside the loci-core engine" (§6.7 — no shared `current`); "`vim.t.loci_workspace_id` mirrors the engine's notion of the active workspace" (no engine notion); "Knowledge notes are real markdown files under `<vault>/.loci/content/`" (§6.1); "Diagnostics (`loci-doctor`)" (no doctor). The *sole-writer* paragraph survives (arch §12 still has the engine as the writer) but the specifics die. |
| `docs/workspace-lifecycle.md` (62) | **wholesale wrong** | `loci start-work` CLI; palette `workspace.create`/`start-work`; "Activation applies the engine's editor-state plan (cwd, haunt, resession, wayfinder)" (§6.7); "▸ reconcile workspace" (§18); "▸ deactivate workspace" (no activation); "knowledge notes & linked files" hub rows. The `workspace.archive` *concept* survives as `workspaces/archive`. |
| `docs/obsidian-symlink-setup.md` (23) | **mostly wrong** | "Loci exposes only `<vault>/.loci/content/`" (§6.1 — no jail; documents live at real paths). The "client no longer manages symlinks" stance stays true. |
| `docs/tasknotes-delegation.md` (19) | **largely fine** | Task delegation is still true (V2 has no task state). "A workspace may associate with a task's markdown note so activation restores the right context" — activation phrasing only. |
| `docs/troubleshooting.md` (74) | **mostly wrong** | `:LociDoctor` hub + "Fix all missing loci_id" (no doctor/doctor_fix); `uv tool install …/lsp loci-lsp`; "run **reconcile** from the status hub" (§18); "`doctor_fix` only fixes `missing_loci_id`" (gone). The PATH/attach advice survives. |
| `README.md` (root, 28) | **partially wrong** | "thin loci-lsp client + the loci-lsp server binary" — the binary arm is dead until §3 is decided. Repoman boilerplate survives. |
| `AGENTS.md` | **partially wrong** | "re-exports loci-core's `loci-lsp`" (no such package); "the real test gate is loci-core's pytest/pytest-lsp suite (re-exported as the flake check)" — the current engine's flake has **empty checks** (`loci-core/flake.nix:50`) and **no pytest-lsp suite**; "loci ships only the `:Loci*` user-commands" (still true) and "loci leader maps live in nix-nvim" (still true). |

---

## 5. Test delta

Current suite: 23/23 pass against the **pinned pre-V2** protocol. Against the V2 engine (or a
V2 host) they classify as follows. **Dangerous ones — tests that keep passing *against a dead
protocol* — are t01–t16 and t19**, which assert against the **fakeservers**, not the real wire;
they would stay green indefinitely while testing a protocol nothing will ever serve again.

| Test | What it pins | Against V2 |
|---|---|---|
| t01 module load (8 commands registered) | self-init | **dead-but-green** — commands still register; surface is wrong |
| t02 no-client warn | attach guard | **keeps** — protocol-free |
| t03 latency notice (`fs_slow`) | server-starting UX | **keeps** (mechanics), fake dies |
| t04/t05/t06/t07 (`fs_index`) | `project.index`/`workspace.index` reads, root anchoring, pinned checktime | **dead-but-green** — ops gone; the checktime mechanics (t07) survive in principle |
| t08/t09 (`fs_commands`) | palette create/start-work open, `editor_state` churn | **dead-but-green** — `loci/commands`, `loci.start-work` gone |
| t10/t11 (`fs_activate` + real resession) | activation routing, global-session guard | **dead-but-green** — activation gone |
| t12/t13 (`fs_status` + resession/wayfinder stubs) | deactivate plan, wrong-tab guard | **dead-but-green** — deactivate gone |
| t14 (`fs_commands`) | `prompt_args` kinds | **dead-but-green** — palette arg specs gone |
| t15 (`fs_doctor`) | unsaved-buffer clobber warning | **dead-but-green** — `doctor` read gone; the F7 warning mechanics survive |
| t16 (`fs_index` shim) | server-death hygiene | **keeps** (host-side) after fakeserver rewrite |
| t17 (**real** loci-lsp) | real-server exit flavors | **breaks** — binary is pre-V2; nothing V2 to spawn |
| t18 (`fs_activate` + git) | git writeback resolution | **dead-but-green** — `set_editor_state` gone |
| t19 (`fs_index`) | `vim.lsp.commands` interception (`loci.note.update`…) | **dead-but-green** — those commands gone; dispatch must move to `action_id` |
| t20 (**real** fullstack) | `loci.repository.init` + `M.daily()` + open | **breaks** — init command and `note.daily` gone; vault bootstrap has no wire path |
| t21 (real plugins) | `editor_state` against haunt/resession | **breaks** — activation gone |

**What `fakeservers/` must become:** the six fake servers encode `loci/op` +
`workspace/executeCommand` + `loci/commands`. The V2 wire is `didOpen/didChange/didSave/didClose`
+ `diagnostics` + `code_actions` + `execute_action` (plus whatever the new host adds for the 24
features — see §3). Realistic options: (a) rewrite the fakes to serve the adapter's own methods
(they can even *import* `apps.lsp.adapter` over a fake `Loci`), or (b) drop the Lua harness's
server faking entirely and let the remaining host-side tests (t02, t03, t16) run against a shim
that only simulates lifecycle. The pytest-lsp gate the AGENTS.md claims is **already gone** from
the current engine (empty checks) — a decision on the real gate is required (§3 + 03-OPEN-QUESTIONS).

---

## 6. New engine capabilities loci.nvim should adopt

A losses-only report would be incomplete. The current engine **gains** these, all reachable:

1. **Real diagnostic ranges + calibrated families** (D-041, D-047) — `unmanaged` (info, filter by
   default per arch §13), `missing_target`, `ambiguous_link`, `degraded_identity` at real spans.
   The plugin's "diagnostics anchor at line 0" limitation is now *fixed engine-side*; the client
   gains a working diagnostic story for free once a host exists.
2. **Preview-first route** (D-032, `registry.py` `preview=`) — every mutating feature declares a
   pure preview. The client's dry-run-then-confirm pattern gets a *correct* server: call preview,
   show, then call the handler. No more `dry_run` arg guessing.
3. **CAS everywhere** — `did_save` (D-041), `move` (D-037), `archive` (D-029), code-action
   `expected_hash` (`adapter.py:166-170`). The client can surface honest conflicts instead of
   assuming success.
4. **Consistency + revision named on every result** (arch §10.2, CLI prints it) — the client can
   show staleness instead of hiding it (e.g. statusline `loci: <rev> <mode>`).
5. **Graph queries** — `graph/broken_links`, `graph/missing_attachments`, `graph/ambiguous_links`,
   `graph/orphans`, `graph/traversal`, `graph/backlinks`, `graph/neighbors`,
   `graph/project_members`. These are natural new hubs (a "vault health" hub replacing doctor; a
   backlinks/neighbors view per note — the old plugin had *no* graph story at all).
6. **`search/text` (FTS5)** — real full-text search the old engine never offered the client.
7. **`documents/create` with validated names** (D-028) and **`documents/move`** — the plugin's
   note-creation gets engine validation + the first path-changing capability.
8. **`maintenance/refresh` with a real `changed_sources` count and `diagnostics_summary`** —
   a truthful "N files changed" UI and a per-code diagnostic rollup to replace the dead doctor.
9. **`documents.set_status` as the ONE shared-property writer** (D-027) — a code-action surface
   that refuses bad values with a typed reason the client can show, instead of silently corrupting.
10. **`workspaces.put/get/list/archive` with composition preserved** (D-029) — workspace CRUD
    that round-trips the manifest; `workspaces/get` returns `documents` (ref, role, resource_id,
    state, current_path) + `files` — a *better* workspace view than the old `knowledge.objects`.
