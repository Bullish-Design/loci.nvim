# 04 — Wire contract: the `loci-lsp` V2 host (Option 1a)

This is the **client-side spec** the rebuilt `lua/loci/init.lua` and its fakeservers are written
against. The loci-core `apps/lsp` host (pygls, per Q1/Option 1a) should implement exactly this so
the plugin and the engine agree. Deviations here are contract changes and must be coordinated.

Sources of truth the host derives from: `src/loci_core/protocol/registry.py` (24 features, wire
names, request models), `apps/cli/main.py` (envelope + `_to_json` projection + preview routing),
`apps/lsp/adapter.py` (LSP methods, diagnostics, actions).

---

## Transport

Content-Length-framed JSON-RPC 2.0 over stdio — the standard LSP wire. Binary name: `loci-lsp`.
Standard lifecycle (shutdown/exit) per LSP.

## Lifecycle methods

| Method | Behavior |
|---|---|
| `initialize` | Capabilities: `textDocumentSync: {openClose: true, change: 1, save: true}` — **object form** so nvim sends `didSave` (the adapter returns the number `1`, which does *not* advertise save; the host must widen it — this is the client contract). Plus `diagnosticProvider: {interFileDependencies: false, workspaceDiagnostics: false}`. No completion. |
| `textDocument/didOpen` | `adapter.did_open(uri, text, version)` — captures the disk hash as the save CAS base. |
| `textDocument/didChange` | `adapter.did_change(uri, text, version)` — full-text (change: 1). |
| `textDocument/didSave` | `adapter.did_save(uri)` → `{committed, reason, revision}`. **`didSave` is a notification with no response** — the host must send the result back as the custom notification **`loci/saveResult`** with params `{uri, committed, reason, revision}` after every save. The client notifies on `committed: false` (except `reason == "unchanged"`, which is silent). |
| `textDocument/didClose` | `adapter.did_close(uri)`. |
| `textDocument/diagnostic` | **Pull** diagnostics: nvim sends this request when the server advertises `diagnosticProvider`. Respond `{kind: "full", items: adapter.diagnostics(uri)}` — a RAW LSP result, NOT the feature envelope. (The host may also push `textDocument/publishDiagnostics` for hosts that do not pull; nvim prefers pull.) Client filters `unmanaged` (code) on both paths. |
| `textDocument/codeAction` | `adapter.code_actions(uri)` → a RAW ARRAY of `[{title, kind, data:{action_id, path, expected_hash, args}}]` (LSP result, not enveloped). The host **adds a `command` field** to each: `command: {title, command: "loci.action.execute", arguments: [{uri, action_id, path, expected_hash, args}]}` so standard clients (tiny-code-action → `client:exec_cmd`) can execute. |
| `workspace/executeCommand` | Only command: `"loci.action.execute"`, `arguments: [{uri, action_id, path, expected_hash, args}]` → `adapter.execute_action(uri, action)` → envelope-wrapped `{ok: true, value: {applied, commit}}` (or `{applied: false, reason}`). |

## Feature methods — `loci/<wire_name>`

For every registry feature, a custom method named **`loci/<wire_name>`** (e.g. `loci/documents/list`,
`loci/workspaces/put`, `loci/graph/broken_links`, `loci/maintenance/refresh`).

- **Params:** one JSON object whose keys are the request model's field names (snake_case as in the
  dataclasses: `{ref: "notes/a.md"}`, `{workspace_id: "..."}`, `{include_archived: true}`,
  `{name: "x", kind: "project", body: "..."}`). Omitted optional fields take the model defaults.
  (`VaultPath` fields accept plain relative paths.)
- **Response — the CLI envelope, always:** `{ok: true, value: <projected result>}` or
  `{ok: false, error: {kind: <LociError subclass name>, message: <str>}}`.
- **Projection:** the CLI `_to_json` semantics — dataclass → `{field: value}` (incl. `None`), nested
  dataclasses recursively, `VaultPath`/`Path` → `str`, `bytes` → utf-8-with-replace, tuples/lists →
  arrays. For results carrying a `revision`, append `_revision` (str) and `_consistency` (mode str)
  to `value` (exactly the CLI's `_as_snapshot` behavior).
- **Preview route for mutating features:** `loci/<wire_name>/preview` — same params, calls the
  feature's declared pure `preview` (D-032), returns `{ok: true, value: <CommandPreview projection>}`
  and **never writes**. `CommandPreview` projects as `{command, refusals: [...], changes: [{kind,
  path, destination, before_excerpt, after_excerpt, diagnostics}]}`.

## Feature wire names (24, registry-derived)

`documents/get|list|preview_adoption|adopt|create|format_owned|set_status|move` ·
`relations/add_project|remove_project` · `workspaces/put|get|list|archive` ·
`maintenance/refresh` · `search/text` ·
`graph/backlinks|neighbors|project_members|broken_links|missing_attachments|ambiguous_links|orphans|traversal`

Preview routes exist for the 9 mutating features: `documents/adopt|create|format_owned|set_status|move`,
`relations/add_project|remove_project`, `workspaces/put|archive`.

## Key result shapes the client renders (VERIFIED against the CLI, 2026-08-05)

Every feature value carries **`_revision` and `_consistency`** (all feature handlers return
`SnapshotResult`; the CLI appends them unconditionally). The result dataclasses are wrapped:

| Method | Value shape (post-projection) |
|---|---|
| `documents/get` | `{document: DocumentView, _revision, _consistency}` — `DocumentView` = `{path, id, kind, title, status, state, identity_state}` |
| `documents/list` | `{documents: [DocumentView…], _revision, _consistency}` |
| `documents/create` (commit) | `{document: DocumentView\|null, commit, revision, _revision, _consistency}` |
| `workspaces/list` | `{workspaces: [WorkspaceView…], _revision, _consistency}` |
| `workspaces/get` | `{view: WorkspaceView, _revision, _consistency}` — `WorkspaceView` = `{id, name, path, project, archived, documents: [[ref, role, resource_id, state, current_path]…], files: [[path, role]…]}` |
| `workspaces/put` | `{workspace_id, path, commits, adopted_members, revision, _revision, _consistency}` |
| `workspaces/archive` | `{view: WorkspaceView, commit, revision, _revision, _consistency}` |
| `maintenance/refresh` | `{revision, consistency, changed_sources, diagnostics_summary: [[code, count]…], _revision, _consistency}` |
| `search/text` | `{results: [[path, resource_id, management_state, title, snippet, score]…], _revision, _consistency}` |
| `graph/backlinks` | `{rows: [[source_path, kind, raw_target]…], _revision, _consistency}` |
| `graph/broken_links` | `{rows: [[source_path, raw_target, kind]…], _revision, _consistency}` |
| `graph/missing_attachments` / `graph/ambiguous_links` | `{rows: [[source_path, raw_target]…], _revision, _consistency}` |
| `graph/orphans` | `{rows: [path…], _revision, _consistency}` |
| `graph/traversal` | `{rows: [[path, depth]…], _revision, _consistency}` |
| `loci/<wire>/preview` (mutating) | `{command, refusals: […], changes: [{kind, path, destination, before_excerpt, after_excerpt, diagnostics}…]}` — the CLI's CommandPreview projection (verified: `documents/create` preview without `--apply` returns exactly this, plus `_committed: false` in JSON mode; the host may include `_committed: false` too) |

## Startup failure modes the client must surface

- Server binary absent → client `executable("loci-lsp")` guard (existing).
- Vault dir exists but no `.loci/vault.toml` → **client refuses to attach** and warns
  "vault not initialized — run `loci init`" (the engine raises `VaultNotInitialized`; there is no
  wire init path yet — Q2).
- Engine `VaultPolicyError` (no FTS5, `kernel.py:96`) → surfaces as a server initialize/start
  failure through the client's `on_error`/`on_exit` path.

## Deliberate non-contract (gone from V2)

`loci/op`, `workspace/executeCommand`-as-generic-effect, `loci/commands`, `textDocument/completion`,
`.loci/content/` paths, `editor_state` blocks, activation/deactivation — none of these exist and the
client must not send them.
