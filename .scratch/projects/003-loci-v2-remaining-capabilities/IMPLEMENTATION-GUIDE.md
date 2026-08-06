# 003 — Implement the remaining V2 capabilities in loci.nvim

**Scope:** every item left open after project 002 (`002-loci-core-v2-realignment`):
link-a-file-to-workspace, registry-derived palette (Q5), `graph/neighbors`/`traversal`
views, `documents/move` UI, standalone adoption verb, statusline staleness segment,
plus the Q3 `unmanaged` escape hatch. Project 002's P0–P2 and P3.1/P3.2-search are
**done** and verified (lock @ `4a8d5e2`, 17/17 suite, `nix flake check` green).

**Ground rules (from AGENTS.md — do not break):**
- `lua/loci/init.lua` is ONE thin client file. No loci logic client-side — every
  semantic decision stays in `loci-core`. All writes go through feature methods
  (`loci/<wire>`) or `loci.action.execute`, then `:checktime`.
- Mutating features are **preview-then-apply** (the declared pure `/preview` route,
  D-032) — never a client-side diff, never a blind apply.
- The engine is the sole writer of vault files. The client owns only host state
  (`vim.t.loci_workspace_id`, `vim.t.loci_state`).
- Wire truth = `002-loci-core-v2-realignment/04-WIRE-CONTRACT.md`; the executable
  reference = `.scratch/tests/fakeservers/fs_v2.py`.
- In-repo ops go through `devenv shell -- <cmd>`.

---

## Work-item inventory

| # | Work item | Wire method(s) | Status today |
|---|---|---|---|
| A | Standalone adoption verb | `documents/adopt` (+`/preview`) | reachable only via code action |
| B | `documents/move` UI | `documents/move` (+`/preview`) | none (preview renderer already handles `kind == "move"`) |
| C | `graph/neighbors` view | `graph/neighbors` | none |
| D | `graph/traversal` view | `graph/traversal` | none |
| E | Link-a-file-to-workspace | `workspaces/put` `files`/`documents` lists (+`/preview`) | `workspaces/put` used for create only |
| F | `unmanaged` escape hatch (Q3) | — (client filter) | filter is unconditional |
| G | Registry-derived palette (Q5) | 24 `loci/<wire>` methods | static 10-verb list |
| H | Statusline staleness segment | — (client state) | `vim.t.loci_state` populated, unconsumed |

**Optional extra (same shape as C/D):** `graph/project_members` is also in the 24-wire
registry and unwired — a per-project members picker costs ~20 lines once C/D land.

---

## Decisions to confirm with loci-core first (read before coding)

1. **`workspaces/put` merge vs replace.** Does a PUT with `files`/`documents` *replace*
   the manifest or *merge*? The link-file flow must know: if it replaces, the client must
   **read-modify-write** — `workspaces/get` the current view, append the new member, PUT
   the full list. If it merges, PUT just the new member. Default assumption (safe): **read
   the view, append, PUT** — it works under either semantics. Confirm in
   `loci-core/src/loci_core/features/workspaces.py` before finalizing.
2. **`graph/neighbors` result shape.** Not in the contract's result-shapes table
   (only `backlinks`, `broken_links`, `missing_attachments`, `ambiguous_links`,
   `orphans`, `traversal` are documented). Likely `{rows: [[path, kind]…]}`. Confirm the
   CLI projection (`loci-core/apps/cli/main.py` + registry) and update
   `04-WIRE-CONTRACT.md`'s result-shape table in the same commit.
3. **`documents/move` request fields.** Likely `{ref: <VaultPath>, destination: <VaultPath>}`
   (check `protocol/registry.py`). Also confirm the committed result shape (probably
   `{document, commit, revision, _revision, _consistency}` like `create` — if so, reuse
   `open_new_document` after apply).
4. **`graph/traversal` params.** Likely `{ref, max_depth?}`. The documented shape is
   `{rows: [[path, depth]…]}` — good.
5. **`documents/adopt` params.** `{ref}` (VaultPath), result like `create`. The code
   action already uses it; the standalone verb mirrors the code action's params.
6. **Registry introspection (Q5, engine-side option).** A *true* registry-driven palette
   would need a wire method exposing the registry (e.g. `loci/registry` returning the 24
   wire names + request fields). That is a loci-core change, out of scope here. This guide
   implements the pragmatic version: a **client-mirrored registry table** (wire name,
   label, arg prompts) kept in sync with `04-WIRE-CONTRACT.md`, with the engine-side
   option noted in docs. Do not block on it.

---

## Phase 0 — Verify the baseline

```bash
devenv shell -- bash .scratch/tests/run-tests.sh        # expect 17/17
devenv shell -- nix flake check                          # expect all green
git -C . status --short                                   # clean tree
```

All later phases must keep the suite green at every step. Phase 1 first: **extend the
fakeserver before the client**, so every client change is gated against the contract the
moment it lands.

---

## Phase 1 — Extend the fakeserver (`fakeservers/fs_v2.py`)

Add defaults so the new methods return the documented shapes. `feature_value` already
appends `_revision`/`_consistency` via `_env`.

```python
"loci/graph/traversal": {"rows": [["notes/a.md", 0], ["notes/b.md", 1], ["notes/c.md", 1]]},
# neighbors shape TBD (decision #2); start from the CLI projection, e.g.:
"loci/graph/neighbors": {"rows": [["notes/b.md", "wikilink"], ["notes/c.md", "wikilink"]]},
"loci/documents/adopt": {
    "document": _doc("notes/a.md", title="a", state="managed"),
    "commit": {"status": "committed"}, "revision": "r1",
},
"loci/documents/adopt/preview": {
    "command": "documents/adopt", "refusals": [],
    "changes": [{"kind": "update", "path": "notes/a.md",
                 "before_excerpt": "", "after_excerpt": "loci: id-a"}],
},
"loci/documents/move": {
    "document": _doc("notes/b.md", title="b"),
    "commit": {"status": "committed"}, "revision": "r1",
},
"loci/documents/move/preview": {
    "command": "documents/move", "refusals": [],
    "changes": [{"kind": "move", "path": "notes/a.md", "destination": "notes/b.md"}],
},
```

Also make the fake's `workspaces/put` echo any `files`/`documents` from the request into
its value (the current default ignores params) so the link-file test can assert round-trip:

```python
# in feature_value() or handle_request(): for method == "loci/workspaces/put"
# and "loci/workspaces/put/preview", merge params["files"]/params["documents"] into the value.
```

**Verify:** `python3 -m py_compile fakeservers/fs_v2.py`; suite still 17/17.

---

## Phase 2 — Standalone adoption verb (work item A)

**File:** `lua/loci/init.lua`, in the "note quick-commands" section (after `M.new_note`).

Adopt the **current buffer's document** (compute the vault-relative path exactly like
`M.backlinks` does). Reuse `preview_then_apply` — the renderer already shows the
`update` excerpt, and `apply_effect` reloads via `:checktime`.

```lua
-- Standalone adoption verb: `documents/adopt` for the current buffer's document.
-- Reachable today only through code actions; this is the direct surface. The engine
-- validates (managed doc, `loci:` region write); we only compute the ref and confirm.
function M.adopt()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = root_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not root or name == "" then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  local rel = name:gsub("^" .. vim.pesc(root), ""):gsub("^/+", "")
  if rel == "" then
    notify("not a vault file", vim.log.levels.WARN)
    return
  end
  preview_then_apply("documents/adopt", { ref = rel }, function()
    return "Adopt " .. rel .. "?"
  end, bufnr)
end
```

**Also:** add a `LociAdopt` user command (bottom of file) and a palette entry (Phase 7).

---

## Phase 3 — `documents/move` UI (work item B)

**File:** `lua/loci/init.lua`, same section.

Move the current buffer's document: prompt for a destination vault-relative path, preview
(the renderer already prints `move src → dest`), apply, then open the moved file (reuse
`open_new_document` if the result carries `.document`, per decision #3).

```lua
-- Move the current buffer's document (`documents/move`, preview route D-032). The
-- destination is a vault-relative path; the engine validates + plans the move.
function M.move_document()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = root_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not root or name == "" then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  local rel = name:gsub("^" .. vim.pesc(root), ""):gsub("^/+", "")
  if rel == "" then
    notify("not a vault file", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Move to (vault-relative path): " }, function(dest)
    if not dest or vim.trim(dest) == "" then
      return
    end
    dest = vim.trim(dest)
    if dest:sub(1, 1) == "/" or dest:find("\\") or dest:match("(^|/)%.%./") then
      notify("destination must be a vault-relative path", vim.log.levels.WARN)
      return
    end
    preview_then_apply("documents/move", { ref = rel, destination = dest },
      function() return ("Move %s → %s?"):format(rel, dest) end,
      bufnr, function(value)
        open_new_document(value, bufnr)  -- opens value.document.path (decision #3)
      end)
  end)
end
```

**Also:** `:LociMove` command; palette entry.

---

## Phase 4 — Graph views: `neighbors` + `traversal` (work items C, D)

**File:** `lua/loci/init.lua`, in the "search / backlinks" section (right after
`M.backlinks`). Both mirror the backlinks picker: compute the current buffer's
vault-relative ref, read the graph method, render rows as a picker that opens paths.

```lua
-- Per-note graph pickers (`graph/neighbors` + `graph/traversal`). Traversal rows carry
-- a depth ([[path, depth]…]); neighbors rows carry the link kind. First column is
-- always the source path. Same ref-resolution shape as M.backlinks.
local function graph_picker(wire, prompt_fmt)
  local bufnr = vim.api.nvim_get_current_buf()
  local root = root_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not root or name == "" then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  local rel = name:gsub("^" .. vim.pesc(root), ""):gsub("^/+", "")
  if rel == "" then
    notify("not a vault file", vim.log.levels.WARN)
    return
  end
  M.read(wire, { ref = rel }, function(value)
    vim.schedule(function()
      local items = {}
      for _, r in ipairs((value and value.rows) or {}) do
        local path, extra = r[1], r[2]
        local suffix = (wire == "graph/traversal") and ("  (depth " .. tostring(extra) .. ")") or ""
        items[#items + 1] = {
          text = tostring(path) .. suffix .. (extra and wire == "graph/traversal" and "" or ("  [" .. tostring(extra) .. "]")),
          path = path,
        }
      end
      pick(items, (prompt_fmt or wire):format(rel), function(item)
        if item.path then
          open_vault_path(item.path, bufnr)
        end
      end)
    end)
  end, bufnr)
end

function M.neighbors()
  graph_picker("graph/neighbors", "Neighbors of %s")
end

function M.traversal()
  graph_picker("graph/traversal", "Traversal from %s")
end
```

**Note the double-suffix bug trap in the sketch above** — decide ONE suffix scheme per
wire (traversal: `(depth n)`; neighbors: `[kind]`) and drop the other; don't copy the
`and/or` expression verbatim. If `graph/traversal` needs a `max_depth` param (decision
#4), prompt for it and pass it through.

**Also:** `:LociNeighbors`, `:LociTraversal` commands; palette entries.

**Optional (same shape):** `M.project_members()` over `graph/project_members` — rows of
member paths; only if the registry's shape is confirmed (decision #2 covers the
unverified rows).

---

## Phase 5 — Link-a-file-to-workspace (work item E)

**File:** `lua/loci/init.lua`, workspace section (near `M.status`/`M.workspaces`).

The old `loci.link_file` reincarnates as `workspaces/put` with a `files` (and optionally
`documents`) list. Per decision #1 (default read-modify-write): read the pinned
workspace's view, append `[path, role]`, PUT the full state, preview-first.

Roles (from docs/README): `implementation`, `reference`, `related`, `documentation`,
`test`.

```lua
local ROLES = { "implementation", "reference", "related", "documentation", "test" }

-- Link the CURRENT buffer's file to the tab-pinned workspace (`workspaces/put` files
-- list). Read-modify-write from workspaces/get (put semantics may be replace — see 003
-- decisions); preview-then-apply; refresh the status hub afterward.
function M.link_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local wid = vim.t.loci_workspace_id
  local root = root_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not wid then
    notify("no workspace pinned in this tab — :LociWorkspaces to pick one", vim.log.levels.INFO)
    return
  end
  if not root or name == "" then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  local rel = name:gsub("^" .. vim.pesc(root), ""):gsub("^/+", "")
  if rel == "" then
    notify("not a vault file", vim.log.levels.WARN)
    return
  end
  pick(vim.tbl_map(function(r) return { text = r } end, ROLES), "Role for " .. rel .. ":", function(role_item)
    local role = role_item and role_item.text
    if not role then
      return
    end
    M.read("workspaces/get", { workspace_id = wid }, function(value)
      vim.schedule(function()
        local ws = value and value.view
        if not ws then
          notify("workspace " .. tostring(wid) .. " not found", vim.log.levels.WARN)
          return
        end
        local files = {}
        for _, f in ipairs(ws.files or {}) do
          files[#files + 1] = { f[1], f[2] }
        end
        for _, f in ipairs(files) do
          if f[1] == rel then
            notify(rel .. " is already linked (" .. tostring(f[2]) .. ")")
            return
          end
        end
        files[#files + 1] = { rel, role }
        preview_then_apply("workspaces/put",
          { workspace_id = wid, files = files },
          function() return ("Link %s as %s?"):format(rel, role) end,
          bufnr, function() M.status() end)
      end)
    end, bufnr)
  end)
end
```

**Also:** `:LociLinkFile` command; a `▸ link current file` row in `M.status`'s rows
(before the archive row) that calls `M.link_file`; palette entry.

---

## Phase 6 — `unmanaged` escape hatch (work item F, Q3)

**File:** `lua/loci/init.lua`, diagnostic-filter section. The filter (today unconditional)
consults `vim.g.loci_show_unmanaged` (default `false`), and a command flips it.

```lua
-- Q3 escape hatch: arch §13 endorses filtering `unmanaged` entirely by default; a user
-- who wants the informational rows sets vim.g.loci_show_unmanaged (or :LociToggleUnmanaged).
local function filter_loci_unmanaged(items)
  if vim.g.loci_show_unmanaged then
    return items or {}
  end
  local out = {}
  for _, d in ipairs(items or {}) do
    if not (d.code == "unmanaged") then
      out[#out + 1] = d
    end
  end
  return out
end

function M.toggle_unmanaged()
  vim.g.loci_show_unmanaged = not vim.g.loci_show_unmanaged
  notify("unmanaged diagnostics " .. (vim.g.loci_show_unmanaged and "shown" or "filtered"))
end
```

**Also:** `:LociToggleUnmanaged` command; palette entry (toggle verbs live in a
"settings" category). Test t12 must still pass (default stays filtered).

---

## Phase 7 — Registry-derived palette (work item G, Q5)

**File:** `lua/loci/init.lua` — replace `M.palette`'s static list with a table mirrored
from the 24-wire registry (`04-WIRE-CONTRACT.md`). Two entry kinds:

- **read features** → run `M.read(wire, args)`, then `pick` the results (rows carry a
  path/action like the hubs);
- **mutating features** → prompt args (`vim.ui.input` per arg), then
  `preview_then_apply`.

Keep the existing bespoke verbs (daily/scratch/new-note) as entries on top. The table is
the single source of the surface; adding future verbs = adding a row.

```lua
-- Client-mirrored registry (Q5; engine-side introspection is a loci-core option — see
-- 003 decisions). One row per surface entry: label, category, wire, args to prompt,
-- read (true) or mutating (false). Arg prompts are UI-only; the engine validates.
local PALETTE_ITEMS = {
  { text = "New note",           action = function() M.new_note() end },           -- bespoke verb
  { text = "Daily note",         action = function() M.daily() end },
  { text = "Scratch note",       action = function() M.scratch() end },
  { text = "Adopt current note", action = function() M.adopt() end },
  { text = "Move current note",  action = function() M.move_document() end },
  { text = "Projects",           action = function() M.projects() end },
  { text = "Workspaces",         action = function() M.workspaces() end },
  { text = "Status / workspace context", action = function() M.status() end },
  { text = "Link current file to workspace", action = function() M.link_file() end },
  { text = "Vault health",       action = function() M.doctor() end },
  { text = "Search",             action = function() M.search() end },
  { text = "Backlinks",          action = function() M.backlinks() end },
  { text = "Neighbors",          action = function() M.neighbors() end },
  { text = "Traversal",          action = function() M.traversal() end },
  { text = "Refresh index",      action = function() M.refresh() end },
  { text = "Toggle unmanaged diagnostics", action = function() M.toggle_unmanaged() end },
}
```

Do NOT ship a generic 24-feature prompt-engine in this pass — that is the part Q5 said
to defer until the typed surface settles, and every wire's arg kinds differ. The
curated table above IS the "registry-derived" surface for now; if the engine later
gains a `loci/registry` introspection method (decision #6), swap the table for it in a
follow-up with the same entry shape.

**Verify:** `:LociPalette` renders all rows; each row's action works end-to-end.

---

## Phase 8 — Statusline staleness segment (work item H)

**File:** `lua/loci/init.lua` (new `M.statusline()`) + docs. `vim.t.loci_state`
(`{revision, consistency}`) is already populated by `request()`; the consumer is
nix-nvim's statusline (downstream in the DAG), but the segment builder + its contract
belong here (host-owned display, arch §10.2).

```lua
-- Statusline segment contract (arch §10.2 — every result names its mode + revision):
--   nil/""        -> nothing observed yet (no vault client or no feature ran)
--   "r1"          -> current (index + files agree)
--   "r1!"         -> consistency is "indexed" (a stale-index read) — surface it
-- Consumers (nix-nvim) call this and render it (e.g. `loci:r1!`). Keep this fn free
-- of vim.ui/pickers so it is safe to call from statusline tickers.
function M.statusline()
  local st = vim.t.loci_state
  if not st or not st.revision then
    return ""
  end
  return st.revision .. (st.consistency ~= "current" and "!" or "")
end
```

**Also:** document the contract in `docs/state-ownership.md` (replace the "lets a
statusline show staleness" note with the exact segment semantics) and `docs/README.md`
(`loci:<rev>` / `loci:<rev>!`). The actual nix-nvim statusline/keymap wiring is a
**downstream** change — list it in the close-out, don't do it here.

---

## Phase 9 — Tests (new t18–t25)

Model each on the existing hermetic pattern (`t16_create_workspace.lua` is the closest
template: `spawn_fake`, `PICK_MATCH`, `wait_for` on the request log, `expect`, `finish`).

| Test | What it pins |
|---|---|
| `t18_link_file` | `M.link_file`: `workspaces/get` → `workspaces/put/preview` → `workspaces/put` with `files` containing `[[<rel>, role]]`; pinned-workspace gate ("no workspace pinned" when unset) |
| `t19_neighbors` | `M.neighbors`: sends `loci/graph/neighbors` with `{ref}`; a row opens its path |
| `t20_traversal` | `M.traversal`: sends `loci/graph/traversal` with `{ref}`; depth rendered; row opens path |
| `t21_move_document` | `M.move_document`: input dest → `documents/move/preview` shows the `move` line → apply → `documents/move` sent → `:checktime` ran; destination buffer opened (per decision #3) |
| `t22_adopt_standalone` | `M.adopt`: sends `documents/adopt/preview` then `documents/adopt` with `{ref}` = current buffer rel path; buffer reloaded |
| `t23_palette_registry` | `M.palette` renders the new entries (adopt/move/link/neighbors/traversal/toggle); selecting "Neighbors" issues the neighbors request |
| `t24_unmanaged_toggle` | default filter drops `unmanaged` (reuse t12 setup); `:LociToggleUnmanaged` flips `vim.g.loci_show_unmanaged`; with it set, `unmanaged` rows pass through (t12 must keep passing untouched) |
| `t25_statusline_segment` | `vim.t.loci_state` set after a feature response → `M.statusline()` returns `r1`; with `FS_RESPONSE` overriding `_consistency: "indexed"`, returns `r1!` |

**Harness edits:**
- `run-tests.sh` — append the eight entries to the `tests=(…)` array (order after
  `t17_real_fullstack`).
- `fakeservers/fs_v2.py` — Phase 1 defaults (already landed before the client code).

**Verification loop per test:**
```bash
devenv shell -- bash .scratch/tests/run-tests.sh t18   # new test alone
devenv shell -- bash .scratch/tests/run-tests.sh       # full suite (25/25)
```

---

## Phase 10 — Docs

| File | Change |
|---|---|
| `docs/README.md` | Commands table: add `:LociAdopt`, `:LociMove`, `:LociLinkFile`, `:LociNeighbors`, `:LociTraversal`, `:LociToggleUnmanaged`; update the "That's the **entire** command surface" line (it now includes the graph + document verbs); Concepts: note move/adopt/neighbors/traversal under Graph; Diagnostics: note the `unmanaged` toggle |
| `docs/state-ownership.md` | Statusline segment contract: `M.statusline()` semantics (`<rev>` / `<rev>!`), consumed by nix-nvim; note `vim.g.loci_show_unmanaged` is host-side display state |
| `docs/workspace-lifecycle.md` | Link-a-file: `:LociLinkFile` read-modify-write flow + roles |
| `docs/troubleshooting.md` | "move refused" row (engine refusals surface as envelope errors); "link already exists" notice |
| `04-WIRE-CONTRACT.md` (002) | Add the confirmed `graph/neighbors`, `documents/move`, `documents/adopt` result shapes (decisions #2/#3) |

---

## Phase 11 — Close-out

1. **Update `002/05-STATUS.md`:** move the "Remaining (optional, from 02-PLAN P3)" list
   into a "Done in 003" note (or delete it) and cross-reference this guide.
2. **Downstream (nix-nvim, out of this repo — list, don't do):**
   - statusline: consume `M.statusline()` (or read `vim.t.loci_state`) and render
     `loci:<rev>[!]`;
   - `<leader>l` keymaps for the new commands (`LociAdopt`, `LociMove`, `LociLinkFile`,
     `LociNeighbors`, `LociTraversal`);
   - fleet profile rebuild (`/etc/profiles/per-user/andrew`) is still pending from 002.
3. **Final gate:**
   ```bash
   devenv shell -- bash .scratch/tests/run-tests.sh    # 25/25
   devenv shell -- nix flake check                     # both checks green
   git add -A && git commit                             # one logical commit
   ```
4. Bump `VERSION` only if this is a user-visible release; otherwise leave it.

---

## Risk register

| Risk | Mitigation |
|---|---|
| `graph/neighbors` / `documents/move` shapes differ from assumptions | Phase 1 defaults + tests pin the ASSUMED shape; decision #2/#3 confirm against loci-core BEFORE merging; contract table updated in the same commit |
| `workspaces/put` replaces the manifest | Read-modify-write from `workspaces/get` is the default flow (Phase 5) — correct under either semantics; dedupe guards double-links |
| Palette grows unmaintainable | Curated table + category labels; engine-side `loci/registry` introspection noted as the follow-up (decision #6) |
| New tests flake against the fakeserver | Follow t16's exact pattern (request-log assertions, `wait_for`, fresh sandbox per test); never assert on timing |
| Statusline fn called in a ticker | `M.statusline()` is pure table read + string concat — no `vim.schedule`/UI; keep it that way |
