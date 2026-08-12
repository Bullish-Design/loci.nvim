-- loci — a thin Neovim client for the loci-core V2 engine, spoken over the `loci-lsp` server.
--
-- CLEAN-ROOM. Written against the V2 wire contract (see
-- .scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md):
--   * feature methods `loci/<wire_name>` (registry-derived: documents/*, relations/*,
--     workspaces/*, maintenance/*, search/*, graph/*) returning the `{ok, value}` envelope;
--   * preview routes `loci/<wire_name>/preview` (pure, D-032) for mutating features;
--   * code actions via `workspace/executeCommand` `loci.action.execute` (apply-then-reload);
--   * pull diagnostics (`textDocument/diagnostic`, real UTF-16 ranges, D-041) — `unmanaged` is
--     informational and this client filters it by default (arch §13);
--   * `loci/saveResult` notifications carrying the CAS save result (D-041 conflicts).
-- The editor holds NO loci logic — every semantic decision lives server-side in loci-core
-- (`src/loci_core/features.*`); the engine is the SOLE writer of vault files: we run a feature
-- command and `:checktime`. Host-side state that V2 deliberately leaves to the host (arch §6.7):
-- the tab-pinned workspace id (`vim.t.loci_workspace_id`) and the last observed
-- revision/consistency (`vim.t.loci_state`).
--
-- Standard LSP features are wired ELSEWHERE on purpose and must stay that way:
--   * code actions -> the editor's existing `<localleader>a` (tiny-code-action); we only register
--     the `loci.action.execute` interception so writes reload the buffer and errors surface.
--   * diagnostics  -> pulled by nvim (`textDocument/diagnostic`), rendered by `vim.diagnostic`
--     (`unmanaged` filtered).
--   * completion   -> absent in V2; nothing to wire (the old completion handler is gone).
--
-- Self-initializing: `require("loci")` (no `setup()`).
--
-- The `loci-lsp` server binary is provided on PATH by nix-nvim (this repo's flake re-exports
-- loci-core's `packages.<sys>.loci-lsp`). No manual install is needed in the nix fleet; the
-- `attach()` guard below still warns if it is ever absent, and refuses a vault that has no
-- `.loci/vault.toml` (the engine raises `VaultNotInitialized`; initialize the vault first).

local M = {}

local LSP_NAME = "loci"

-- ── small utilities ─────────────────────────────────────────────────────────

-- JSON `null` arrives from the server as `vim.NIL`, not `nil`. Treat both as absent.
local function present(v)
  return v ~= nil and v ~= vim.NIL
end

local function notify(msg, level)
  vim.notify("loci: " .. msg, level or vim.log.levels.INFO)
end

-- The loci client attached to a buffer (default: current). Reads/effects need a vault buffer.
local function client_for(bufnr)
  return vim.lsp.get_clients({ name = LSP_NAME, bufnr = bufnr or 0 })[1]
end

-- Resolve a flow pin to a client: a CLIENT OBJECT (passed as-is — survives buffer wipes and LSP
-- attach churn) or a bufnr (re-resolved via the attachment table).
local function resolve_client(ref)
  if type(ref) == "table" then
    return ref
  end
  return client_for(ref or 0)
end

-- Is the ONLY-blocking absence an initializing client? `get_clients({ name, _uninitialized = true })`
-- also lists READY clients, so distinguish precisely: any loci client that has not finished
-- initialize yet. When true, a read/effect didn't find a vault client because the server is still
-- booting (~4s on first launch), not because the buffer is outside a vault.
local function server_starting()
  for _, c in ipairs(vim.lsp.get_clients({ name = LSP_NAME, _uninitialized = true })) do
    if not c.initialized then
      return true
    end
  end
  return false
end

-- The vault root for resolving paths = the current buffer's client root. Anchored to the buffer
-- on purpose: `vim.lsp.get_clients({ name })[1]` returns the FIRST-attached client, so with two
-- vaults open in one session that resolution opened the WRONG vault's files (cross-vault
-- contamination). Accepts a bufnr OR a client OBJECT (see `resolve_client`).
local function root_dir(ref)
  local c = resolve_client(ref or 0)
  return c and c.config.root_dir or nil
end

local function open_path(p)
  vim.cmd.edit(vim.fn.fnameescape(p))
end

-- Defense-in-depth for server-supplied paths (the engine validates them, but never trust a join
-- blindly): reject absolute paths, backslashes, and `..` traversal components.
local function safe_join(root, rel)
  if not root or not rel then
    return nil
  end
  if rel:sub(1, 1) == "/" or rel:find("\\") or rel:match("(^|/)%.%./") then
    return nil
  end
  return root .. "/" .. rel
end

-- V2 vault file abs path = <root>/<vault-relative path> (arch §6.1: content is NOT confined to a
-- `.loci/content/` jail — documents live at their real paths). `ref` pins the vault of the flow
-- that produced `path`; it may be a bufnr or a client OBJECT (see `resolve_client`).
local function open_vault_path(path, ref)
  local abs = safe_join(root_dir(ref or 0), path)
  if abs then
    open_path(abs)
  end
end

-- snacks-native picker over arbitrary rows; each item carries `.text` (display + match). Falls back
-- to the snacks-backed `vim.ui.select` if the picker call shape ever drifts.
local function pick(items, prompt, on_choice)
  if not items or #items == 0 then
    notify("nothing to pick", vim.log.levels.INFO)
    return
  end
  local ok = pcall(function()
    Snacks.picker.pick({
      title = prompt,
      items = items,
      -- These are action/selection rows, not files; hide the file previewer (else it errors).
      layout = { hidden = { "preview" } },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then
          on_choice(item)
        end
      end,
    })
  end)
  if not ok then
    vim.ui.select(items, {
      prompt = prompt,
      format_item = function(it)
        return it.text
      end,
    }, function(choice)
      if choice then
        on_choice(choice)
      end
    end)
  end
end

-- ── vault detection + broad attach ──────────────────────────────────────────

-- Walk up from the buffer for a `.loci/` directory; the vault root is its parent.
local function vault_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  local start = (name ~= "" and vim.fs.dirname(name)) or vim.uv.cwd()
  local hit = vim.fs.find(".loci", { path = start, upward = true, type = "directory" })[1]
  return hit and vim.fs.dirname(hit) or nil
end

-- Broad attach: ANY file under a vault root attaches, so the features always have a live client.
-- Buffer-anchored features (diagnostics/code actions) are markdown-scoped SERVER-side, so non-note
-- buffers simply receive nothing. `vim.lsp.start` dedups by (name, root_dir, cmd) -> exactly one
-- process per vault. Refuses (with a one-time warn) a vault directory that has no `.loci/vault.toml`
-- — `Loci.open` raises `VaultNotInitialized` (kernel.py:85-96), and there is no wire init path.
local function attach(bufnr)
  local root = vault_root(bufnr)
  if not root then
    return
  end
  if vim.fn.executable("loci-lsp") == 0 then
    vim.notify_once(
      "loci: `loci-lsp` is not on PATH — the server cannot attach. "
        .. "It is normally provided by nix-nvim (this repo's flake re-exports loci-core's loci-lsp).",
      vim.log.levels.WARN
    )
    return
  end
  if vim.fn.filereadable(root .. "/.loci/vault.toml") == 0 then
    vim.notify_once(
      "loci: the vault at " .. root .. " is not initialized (missing .loci/vault.toml). "
        .. "Run `loci init` (or initialize the vault out-of-band) and reopen a vault file.",
      vim.log.levels.WARN
    )
    return
  end
  vim.lsp.start({
    name = LSP_NAME,
    cmd = { "loci-lsp" },
    root_dir = root,
    -- Server-death hygiene: surface client errors, and on exit drop the (now unverifiable) tab
    -- marker and point the user at recovery. The callbacks run in a fast-event context, so every
    -- UI touch goes through vim.schedule; the exit hint fires only on abnormal exits.
    on_error = function(code, err)
      vim.schedule(function()
        notify("lsp error (code " .. code .. "): " .. tostring(err or "unknown"), vim.log.levels.ERROR)
      end)
    end,
    on_exit = function(code, signal)
      vim.schedule(function()
        vim.t.loci_workspace_id = nil
        if code ~= 0 or (signal ~= 0 and signal ~= 15) then
          notify(
            "loci-lsp exited (code " .. code .. ", signal " .. signal .. ") — the vault client is disconnected; "
              .. "reopen a vault file to reattach",
            vim.log.levels.INFO
          )
        end
      end)
    end,
  }, { bufnr = bufnr })
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("loci_attach", { clear = true }),
  callback = function(args)
    attach(args.buf)
  end,
})

-- Minimal LspAttach: no per-buffer loci wiring beyond a marker for discoverability. Do NOT enable
-- `vim.lsp.completion` (V2 has no completion) and do not claim code-action keymaps (that is the
-- editor's `<localleader>a`).
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("loci_lsp_attach", { clear = true }),
  callback = function(args)
    local c = vim.lsp.get_client_by_id(args.data.client_id)
    if c and c.name == LSP_NAME then
      vim.b[args.buf].loci_attached = true
    end
  end,
})

-- ── request primitive ───────────────────────────────────────────────────────

-- Registry-driven read/effect over `loci/<wire>` (or any custom method) -> the `{ ok, value }`
-- envelope. `bufnr` pins the flow's vault (a bufnr or a client OBJECT — see `resolve_client`), so
-- reads stay on the flow's client even if the user switched buffers. No client at all -> "open a
-- file inside a loci vault"; a client still initializing (~4s on first launch) -> a distinct
-- "server still starting" notice. Records the last observed revision/consistency on `vim.t` so a
-- statusline can surface staleness (arch §10.2: every result names its mode + revision).
-- `on_fail` (optional) runs when the request errors or the envelope refuses, AFTER the notice.
-- Callers that fan out over several requests and join the results need it: without it a single
-- failure silently strands the join forever, because `cb` is the only signal a request ever
-- settled (see M.doctor — the 004 F-09 hang).
local function request(method, params, cb, bufnr, on_fail)
  local client = resolve_client(bufnr)
  if not client then
    if server_starting() then
      notify("server still starting (~4s on first launch)", vim.log.levels.INFO)
    else
      notify("open a file inside a loci vault", vim.log.levels.WARN)
    end
    if on_fail then
      on_fail()
    end
    return
  end
  client:request(method, params or vim.empty_dict(), function(err, result)
    if err then
      notify(method .. " failed: " .. (err.message or "request error"), vim.log.levels.ERROR)
      if on_fail then
        on_fail()
      end
      return
    end
    if not (result and result.ok == true) then
      local e = (result and result.error) or {}
      notify(((e.kind and (e.kind .. ": ") or "") .. (e.message or "error")), vim.log.levels.ERROR)
      if on_fail then
        on_fail()
      end
      return
    end
    local value = result.value
    if value and value._revision then
      vim.t.loci_state = { revision = value._revision, consistency = value._consistency }
    end
    cb(value)
  end, 0)
end

-- Read a feature: `require("loci").read("documents/list", { state = "managed" }, cb, bufnr)`.
function M.read(wire, params, cb, bufnr)
  request("loci/" .. wire, params, cb, bufnr)
end

-- Run an effect (a feature method), then reload the buffer (the engine is the sole writer).
-- `:checktime` won't clobber unsaved changes. `ref` pins the effect + reload to the flow's source
-- buffer; a plain `:checktime` reloads only the CURRENT buffer, which may have changed since the
-- flow started. If the target still has unsaved changes after the checktime, it refused to reload:
-- warn NOW, because a later `:w` would silently overwrite the engine's just-written edit.
-- The optional `after(value)` runs post-reload with the effect's response value (note-creating
-- verbs open the created note there).
-- A REFUSED effect is not an error: the engine answers `ok: true` and reports the outcome in
-- `commit.status` (loci-core fs/outcomes.py::CommitStatus). Nothing was written, so say so — this
-- was entirely silent, which reads as "the command did nothing" for one of the most common actions
-- there is (creating a note whose file already exists -> precondition_failed/destination_exists).
--
-- NB the WIRE shape is not the CLI shape. `loci --json documents/create` projects a CommandPreview
-- (`{refusals: [...], _committed: false}`), but the LSP host sends the SourceCommit itself:
-- `{commit: {status, detail, path}, document: null}`. Both are handled — the preview route really
-- does return `refusals` — but `commit.status` is what an effect over LSP actually carries.
local COMMITTED = { source_committed = true, source_committed_cache_failed = true }

local function report_uncommitted(wire, value)
  if not present(value) then
    return false
  end
  local refusals = {}
  for _, r in ipairs(value.refusals or {}) do
    refusals[#refusals + 1] = tostring(r)
  end
  if #refusals > 0 then
    notify(wire .. " refused: " .. table.concat(refusals, "; "), vim.log.levels.WARN)
    return true
  end
  local commit = present(value.commit) and value.commit or nil
  if commit and present(commit.status) and not COMMITTED[commit.status] then
    local why = present(commit.detail) and tostring(commit.detail) or tostring(commit.status)
    local path = present(commit.path) and (" " .. tostring(commit.path)) or ""
    notify(wire .. " did not commit" .. path .. ": " .. why, vim.log.levels.WARN)
    return true
  end
  return value._committed == false
end

local function apply_effect(wire, params, ref, after)
  request("loci/" .. wire, params, function(value)
    vim.schedule(function()
      report_uncommitted(wire, value)
      local target = (type(ref) == "number" and ref ~= 0 and vim.api.nvim_buf_is_valid(ref))
          and ref
        or vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(target) then
        local was_modified = vim.bo[target].modified
        vim.cmd.checktime(tostring(target))
        if was_modified and vim.bo[target].modified then
          notify(
            "the engine wrote " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(target), ":t")
              .. " but that buffer has unsaved changes — a later :w would overwrite the engine's edit "
              .. "(save first, then :checktime or :e)",
            vim.log.levels.WARN
          )
        end
      end
      if after then
        after(value)
      end
    end)
  end, ref)
end

-- Render a `CommandPreview` (the engine's OWN projection — never author a diff client-side):
-- refusals first, then each planned change; `move` renders its destination.
local function summarize_preview(value)
  local lines = {}
  if not present(value) then
    return lines
  end
  for _, r in ipairs(value.refusals or {}) do
    lines[#lines + 1] = "REFUSED: " .. tostring(r)
  end
  local changes = value.changes or {}
  if #changes == 0 and #lines == 0 then
    lines[#lines + 1] = "(no change)"
  end
  for _, c in ipairs(changes) do
    if c.kind == "move" then
      lines[#lines + 1] = string.format("move %s → %s", c.path or "?", c.destination or "?")
    else
      local l = (c.kind or "change") .. " " .. (c.path or "?")
      if c.before_excerpt then
        l = l .. "\n    before: " .. tostring(c.before_excerpt)
      end
      if c.after_excerpt then
        l = l .. "\n    after : " .. tostring(c.after_excerpt)
      end
      lines[#lines + 1] = l
    end
  end
  return lines
end

-- Preview (the feature's DECLARED pure route, D-032 — never a `dry_run` guess) -> confirm -> apply.
-- Optional `after(value)` runs post-apply (e.g. pin a created workspace).
local function preview_then_apply(wire, params, describe, bufnr, after)
  request("loci/" .. wire .. "/preview", params, function(value)
    vim.schedule(function()
      local header = (describe and describe(value)) or (wire .. " — apply?")
      local lines = summarize_preview(value)
      local prompt = (#lines > 0) and (header .. "\n" .. table.concat(lines, "\n")) or header
      vim.ui.select({ "Apply", "Cancel" }, { prompt = prompt }, function(choice)
        if choice == "Apply" then
          apply_effect(wire, params, bufnr, after)
        end
      end)
    end)
  end, bufnr)
end

-- ── workspace pin (host-owned state, arch §6.7 / §4.3) ─────────────────────

-- V2 has no engine-side "active workspace" pointer; the tab owns it. `vim.t.loci_workspace_id`
-- remains the statusline contract (nix-nvim reads it) but is now set by this client, never by the
-- engine. `vim.t.loci_state` carries the last observed revision/consistency for staleness display.
function M.pin(workspace_id)
  vim.t.loci_workspace_id = workspace_id
end

-- The five link roles (docs/README): the engine stores any string, the picker
-- offers the curated set.
local ROLES = { "implementation", "reference", "related", "documentation", "test" }

-- Link the CURRENT buffer's file to the tab-pinned workspace (`workspaces/put`
-- `files` list). The manifest is wholly-owned and a PUT REPLACES the composition
-- (workspaces.py: "update: wholly-owned manifest, atomic full replace" — 003
-- decision #1): the request IS the manifest, so this is a FULL read-modify-write
-- — it round-trips the `workspaces/get` view's project, documents and files, and
-- only then appends `{path, role}` for the current file (a duplicate path is
-- refused client-side before any write). Preview-then-apply (D-032); the status
-- hub refreshes after apply.
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
          files[#files + 1] = { path = f[1], role = f[2] }
        end
        for _, f in ipairs(files) do
          if f.path == rel then
            notify(rel .. " is already linked (" .. tostring(f.role) .. ")")
            return
          end
        end
        files[#files + 1] = { path = rel, role = role }
        local docs = {}
        for _, d in ipairs(ws.documents or {}) do
          docs[#docs + 1] = { ref = d[1], role = d[2] }
        end
        local params = {
          workspace_id = wid,
          name = ws.name,
          files = files,
          documents = docs,
          archived = ws.archived == true,
        }
        if present(ws.project) then
          params.project = ws.project
        end
        preview_then_apply("workspaces/put", params,
          function() return ("Link %s as %s?"):format(rel, role) end,
          bufnr, function() M.status() end)
      end)
    end, bufnr)
  end)
end

-- Statusline staleness segment (arch §10.2 — every result names its mode +
-- revision). `vim.t.loci_state` ({revision, consistency}) is populated by every
-- feature response; the consumer is nix-nvim's statusline (downstream in the
-- DAG), but the segment builder + its contract belong here (host-owned display).
-- Contract:
--   ""        -> nothing observed yet (no vault client, or no feature has run)
--   "<rev>"   -> current (index + files agree)
--   "<rev>!"  -> consistency is "indexed" (a stale-index read) — surface it
-- Consumers (nix-nvim) render e.g. `loci:36df3e9!`. Keep this fn a pure table read
-- + string concat (no vim.schedule/vim.ui) so tickers can call it safely.
--
-- `<rev>` is ABBREVIATED to REV_WIDTH. The engine's revision is a full 64-char
-- content hash (e.g. 36df3e97...c84455); emitting it raw blew out the statusline
-- on a real vault. The fakeserver suite missed this for a while because fs_v2
-- returned a 2-char toy revision ("r1"), so the segment looked fine under test
-- and only misbehaved against the real server — hence the explicit width
-- assertion in t25. Git-style 7 is enough to eyeball a revision change.
local REV_WIDTH = 7

function M.statusline()
  local st = vim.t.loci_state
  if not st or not st.revision then
    return ""
  end
  return tostring(st.revision):sub(1, REV_WIDTH) .. (st.consistency ~= "current" and "!" or "")
end

-- Resolve a workspace manifest `project` ref (id or path) and open its document.
local function resolve_and_open(ref, bufnr)
  if not ref then
    return
  end
  if ref:find("/") or ref:find("%.md$") then
    open_vault_path(ref, bufnr)
  else
    M.read("documents/get", { ref = ref }, function(value)
      vim.schedule(function()
        local doc = value and value.document
        if doc and doc.path then
          open_vault_path(doc.path, bufnr)
        end
      end)
    end, bufnr)
  end
end

-- ── hubs ────────────────────────────────────────────────────────────────────

-- Status / workspace-context hub: the TAB-PINNED workspace's view (WorkspaceView: documents +
-- files), its project, archive/unarchive, refresh. No engine "current" exists; unpinned tabs are
-- told to pick one. Rows open files at their REAL vault-relative paths.
function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local wid = vim.t.loci_workspace_id
  if not wid then
    notify("no workspace pinned in this tab — :LociWorkspaces to pick one", vim.log.levels.INFO)
    return
  end
  M.read("workspaces/get", { workspace_id = wid }, function(value)
    vim.schedule(function()
      local ws = value and value.view
      if not ws then
        notify("workspace " .. tostring(wid) .. " not found (deleted or renamed?) — unpinning", vim.log.levels.WARN)
        vim.t.loci_workspace_id = nil
        return
      end
      local rows = {
        {
          text = string.format("● %s%s", ws.name or ws.id, ws.archived and "  (archived)" or ""),
          action = function() end,
        },
      }
      if present(ws.project) then
        rows[#rows + 1] = {
          text = "  ◆ project: " .. ws.project,
          action = function()
            resolve_and_open(ws.project, bufnr)
          end,
        }
      end
      for _, d in ipairs(ws.documents or {}) do
        local ref, role, state, cur = d[1], d[2], d[4], d[5]
        rows[#rows + 1] = {
          text = string.format("  note  %s (%s) [%s]", ref or "?", role or "", state or ""),
          action = function()
            open_vault_path(cur or ref, bufnr)
          end,
        }
      end
      for _, f in ipairs(ws.files or {}) do
        local path, role = f[1], f[2]
        rows[#rows + 1] = {
          text = "  file  " .. tostring(path) .. (role and (" (" .. role .. ")") or ""),
          action = function()
            open_vault_path(path, bufnr)
          end,
        }
      end
      rows[#rows + 1] = {
        text = "  ▸ refresh index",
        action = function()
          M.refresh(bufnr)
        end,
      }
      rows[#rows + 1] = {
        text = "  ▸ link current file",
        action = function()
          M.link_file()
        end,
      }
      rows[#rows + 1] = {
        text = "  ▸ " .. (ws.archived and "unarchive" or "archive") .. " workspace",
        action = function()
          preview_then_apply("workspaces/archive", { workspace_id = wid, archived = not ws.archived }, function()
            return (ws.archived and "Unarchive" or "Archive") .. " " .. (ws.name or wid)
          end, bufnr)
        end,
      }
      rows[#rows + 1] = {
        text = "  ▸ switch workspace",
        action = function()
          M.workspaces()
        end,
      }
      pick(rows, "Loci status: " .. (ws.name or wid), function(item)
        if item.action then
          item.action()
        end
      end)
    end)
  end, bufnr)
end

-- Workspace switcher: `workspaces/list` -> pin as the tab's workspace (no activation — the engine
-- has none) -> show its status hub. Also offers creating a workspace (`workspaces/put`).
function M.workspaces()
  local bufnr = vim.api.nvim_get_current_buf()
  M.read("workspaces/list", { include_archived = true }, function(value)
    vim.schedule(function()
      local items = {}
      for _, w in ipairs((value and value.workspaces) or {}) do
        items[#items + 1] = {
          text = (w.name or w.id) .. (w.archived and "  (archived)" or ""),
          workspace_id = w.id,
        }
      end
      items[#items + 1] = { text = "＋ create workspace…" }
      pick(items, "Loci workspaces", function(item)
        if item.workspace_id then
          M.pin(item.workspace_id)
          M.status()
        else
          vim.ui.input({ prompt = "Workspace name: " }, function(name)
            if not name or vim.trim(name) == "" then
              return
            end
            preview_then_apply("workspaces/put", { name = vim.trim(name) }, function()
              return "Create workspace: " .. vim.trim(name)
            end, bufnr, function(value)
              if value and value.workspace_id then
                M.pin(value.workspace_id)
              end
            end)
          end)
        end
      end)
    end)
  end, bufnr)
end

-- Project picker: a project is a managed document whose policy-mapped kind is `project`
-- (arch §11.2 — there is no project entity beside the document); open its real path.
function M.projects()
  local bufnr = vim.api.nvim_get_current_buf()
  M.read("documents/list", { state = "managed" }, function(value)
    vim.schedule(function()
      local items = {}
      for _, d in ipairs((value and value.documents) or {}) do
        if d.kind == "project" then
          items[#items + 1] = {
            text = (d.title or d.path) .. (d.status and (" (" .. d.status .. ")") or ""),
            path = d.path,
          }
        end
      end
      pick(items, "Loci projects", function(item)
        open_vault_path(item.path, bufnr)
      end)
    end)
  end, bufnr)
end

-- Vault-health hub (replaces the deleted whole-vault doctor, arch §18): refresh the index and
-- report its `diagnostics_summary`, plus the graph queries that are the V2-native findings
-- (broken links, missing attachments, ambiguous links, orphans — D-047 families).
local function render_health(ref, groups, bufnr)
  vim.schedule(function()
    local rows = {}
    for _, p in ipairs((ref and ref.diagnostics_summary) or {}) do
      rows[#rows + 1] = {
        text = string.format("[%s]  %d", p[1], p[2] or 0),
        action = function() end,
      }
    end
    local labels = {
      broken_links = "broken links",
      missing_attachments = "missing attachments",
      ambiguous_links = "ambiguous links",
      orphans = "orphans",
    }
    for key, label in pairs(labels) do
      local list = groups[key] or {}
      if #list > 0 then
        rows[#rows + 1] = {
          text = string.format("▸ %s (%d)", label, #list),
          action = function()
            local sub = {}
            for _, r in ipairs(list) do
              if type(r) == "table" then
                sub[#sub + 1] = { text = string.format("%s → %s", r[1], r[2]), path = r[1] }
              else
                sub[#sub + 1] = { text = tostring(r), path = tostring(r) }
              end
            end
            pick(sub, "Loci " .. label, function(item)
              if item.path then
                open_vault_path(item.path, bufnr)
              end
            end)
          end,
        }
      end
    end
    if #rows == 0 then
      notify("vault healthy — no diagnostics, broken/ambiguous links, or orphans")
      return
    end
    pick(rows, "Loci health", function(item)
      if item.action then
        item.action()
      end
    end)
  end)
end

-- Fan out the four graph findings and join them into ONE health picker.
--
-- The join must settle even when a leg does not: a refusing/erroring request never calls its `cb`
-- (hence `on_fail`), and a request the server simply never answers calls back at all (hence the
-- deadline). Before 004 F-09 this counted only successes, so a single failed leg left the picker
-- unrendered with no notice — the command looked like it did nothing. Each leg settles at most
-- once and the render fires at most once, so a late reply after the deadline is harmless.
local DOCTOR_DEADLINE_MS = 15000

function M.doctor()
  local bufnr = vim.api.nvim_get_current_buf()
  request("loci/maintenance/refresh", {}, function(ref)
    local groups, settled, rendered = {}, {}, false
    local legs = { "broken_links", "missing_attachments", "ambiguous_links", "orphans" }

    local function render(partial)
      if rendered then
        return
      end
      rendered = true
      if partial then
        local missing = {}
        for _, name in ipairs(legs) do
          if not settled[name] then
            missing[#missing + 1] = name
          end
        end
        notify(
          "vault health is INCOMPLETE — no response for: " .. table.concat(missing, ", "),
          vim.log.levels.WARN
        )
      end
      render_health(ref, groups, bufnr)
    end

    local function collect(name, rows)
      if settled[name] then
        return
      end
      settled[name] = true
      groups[name] = rows or {}
      if #vim.tbl_keys(settled) == #legs then
        render(false)
      end
    end

    for _, name in ipairs(legs) do
      request("loci/graph/" .. name, {}, function(v)
        collect(name, v and v.rows)
      end, bufnr, function()
        collect(name, {})
      end)
    end
    -- Nothing above fires if the server never replies; the deadline renders what did arrive.
    vim.defer_fn(function()
      render(true)
    end, DOCTOR_DEADLINE_MS)
  end, bufnr)
end

-- Refresh the index and report what actually changed (a real count — D-023 fix).
function M.refresh(bufnr)
  request("loci/maintenance/refresh", {}, function(value)
    vim.schedule(function()
      local n = (present(value) and value.changed_sources) or 0
      local ds = (value and value.diagnostics_summary) or {}
      local total = 0
      for _, p in ipairs(ds) do
        total = total + (p[2] or 0)
      end
      notify(
        string.format("refresh: %d source%s changed, %d diagnostic row%s",
          n, n == 1 and "" or "s", total, total == 1 and "" or "s")
      )
    end)
  end, bufnr or 0)
end

-- ── note quick-commands ─────────────────────────────────────────────────────

-- Open the document a create/effect just returned (`DocumentView.path` — a real vault-relative
-- path, NOT a `.loci/content/` jail path).
-- `present()` on the document itself, not just its path: a REFUSED effect answers `ok: true` with
-- `document: null`, and JSON null arrives as `vim.NIL` — which is a truthy userdata in Lua, so the
-- old `value.document and ...` guard passed and then threw "attempt to index a userdata value" on
-- the real server. (The fakeserver's create always succeeds, so only a real vault reached it.)
local function open_new_document(value, ref)
  if present(value) and present(value.document) and present(value.document.path) then
    open_vault_path(value.document.path, ref)
  end
end

-- Daily note: `documents/create` with a date name — §11.2 makes daily a document-creation
-- template; the template lives client-side, the validation (D-028) server-side.
function M.daily()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = os.date("%Y-%m-%d")
  apply_effect("documents/create", { name = name, kind = "daily", body = "# " .. name .. "\n" }, bufnr, function(value)
    open_new_document(value, bufnr)
  end)
end

function M.scratch()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = "Scratch note name: " }, function(name)
    if not name or vim.trim(name) == "" then
      return
    end
    apply_effect("documents/create", { name = vim.trim(name) }, bufnr, function(value)
      open_new_document(value, bufnr)
    end)
  end)
end

-- New note: prompt name (a single filename component — the engine validates too, D-028), then
-- create + open.
function M.new_note()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = "Note name (single filename component): " }, function(name)
    if not name or vim.trim(name) == "" then
      return
    end
    name = vim.trim(name)
    if name:find("/") or name:find("\\") or name:sub(1, 1) == "." then
      notify("note name must be a single filename component (no /, \\, or leading dot)", vim.log.levels.WARN)
      return
    end
    apply_effect("documents/create", { name = name }, bufnr, function(value)
      open_new_document(value, bufnr)
    end)
  end)
end

-- Standalone adoption verb: `documents/adopt` for the CURRENT buffer's document
-- (AdoptRequest: `{path, proposed_id?}` — the code action already uses it; this is
-- the direct surface). The engine validates (managed doc, `loci:` region write);
-- we only compute the vault-relative ref and preview-then-apply (D-032), and the
-- apply path reloads via `:checktime` (the engine is the sole writer).
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
  preview_then_apply("documents/adopt", { path = rel }, function()
    return "Adopt " .. rel .. "?"
  end, bufnr)
end

-- Move the current buffer's document (`documents/move`, preview route D-032).
-- MoveDocumentRequest: `{source, destination}` — the destination is a
-- vault-relative path; the engine validates + plans the move (same_path /
-- destination_exists / source_missing refusals) and CASes the move itself
-- (D-037: no expected_hash field on the wire). The committed result carries
-- `.document` (None if the move was refused), so after apply we open the
-- moved file.
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
    preview_then_apply("documents/move", { source = rel, destination = dest },
      function() return ("Move %s → %s?"):format(rel, dest) end,
      bufnr, function(value)
        open_new_document(value, bufnr) -- value.document.path (decision 003 #3)
      end)
  end)
end

-- ── search / backlinks (new V2 capabilities) ────────────────────────────────

-- Full-text search over `search/text` (FTS5); rows: (path, resource_id, state, title, snippet, score).
function M.search()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.ui.input({ prompt = "Search query: " }, function(q)
    if not q or vim.trim(q) == "" then
      return
    end
    M.read("search/text", { query = vim.trim(q), limit = 50 }, function(value)
      vim.schedule(function()
        local items = {}
        for _, r in ipairs((value and value.results) or {}) do
          items[#items + 1] = {
            text = (r[4] and (r[4] .. "  ") or "") .. "[" .. (r[3] or "?") .. "] " .. (r[1] or ""),
            path = r[1],
          }
        end
        pick(items, "Loci search: " .. q, function(item)
          if item.path then
            open_vault_path(item.path, bufnr)
          end
        end)
      end)
    end, bufnr)
  end)
end

-- Backlinks for the current note (`graph/backlinks`, ref = vault-relative path of the buffer).
function M.backlinks()
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
  M.read("graph/backlinks", { ref = rel }, function(value)
    vim.schedule(function()
      local items = {}
      for _, r in ipairs((value and value.rows) or {}) do
        items[#items + 1] = {
          text = string.format("%s  (%s → %s)", r[1], r[2] or "", r[3] or ""),
          path = r[1],
        }
      end
      pick(items, "Backlinks to " .. rel, function(item)
        if item.path then
          open_vault_path(item.path, bufnr)
        end
      end)
    end)
  end, bufnr)
end

-- Per-note graph pickers (`graph/neighbors` + `graph/traversal`, and the
-- `graph/project_members` reverse-membership view). All three are GraphQueryRequest
-- (`{ref, depth}` — depth defaults to 3; the engine's bounded BFS). Same
-- ref-resolution shape as M.backlinks. Row shapes differ per wire, so the caller
-- supplies a display suffix fn:
--   neighbors:       rows are FLAT paths (strings) — no suffix
--   traversal:       rows are [path, depth]   — "  (depth n)"
--   project_members: rows are [path, kind, title] — "  (kind)"
-- First column is always the path; selecting a row opens it at its real vault path.
local function graph_picker(wire, prompt_fmt, suffix_fn)
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
        local path = (type(r) == "table") and r[1] or r
        items[#items + 1] = {
          text = tostring(path) .. (suffix_fn and suffix_fn(r) or ""),
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
  graph_picker("graph/traversal", "Traversal from %s", function(r)
    return string.format("  (depth %s)", tostring(r[2]))
  end)
end

function M.project_members()
  graph_picker("graph/project_members", "Project members of %s", function(r)
    return string.format("  (%s)", tostring(r[2]))
  end)
end

-- ── palette ─────────────────────────────────────────────────────────────────

-- Command palette: a static picker over the client's OWN verbs, mirrored from the
-- 24-wire registry (04-WIRE-CONTRACT.md). The old engine-driven `loci/commands`
-- palette is gone (§11.2). A TRUE registry-INTROSPECTED palette would need a
-- loci-core wire method (e.g. `loci/registry` returning the wire names + request
-- models) — that is an engine-side option, out of scope here (003 decision #6);
-- this curated table IS the registry-derived surface for now, and adding a verb =
-- adding one row. Read features run M.read + pick; mutating features prompt args
-- then preview_then_apply; bespoke verbs (daily/scratch/new-note) stay on top.
local PALETTE_ITEMS = {
  { text = "New note", action = function() M.new_note() end }, -- bespoke verb
  { text = "Daily note", action = function() M.daily() end },
  { text = "Scratch note", action = function() M.scratch() end },
  { text = "Adopt current note", action = function() M.adopt() end },
  { text = "Move current note", action = function() M.move_document() end },
  { text = "Projects", action = function() M.projects() end },
  { text = "Workspaces", action = function() M.workspaces() end },
  { text = "Status / workspace context", action = function() M.status() end },
  { text = "Link current file to workspace", action = function() M.link_file() end },
  { text = "Vault health", action = function() M.doctor() end },
  { text = "Search", action = function() M.search() end },
  { text = "Backlinks", action = function() M.backlinks() end },
  { text = "Neighbors", action = function() M.neighbors() end },
  { text = "Traversal", action = function() M.traversal() end },
  { text = "Project members", action = function() M.project_members() end },
  { text = "Refresh index", action = function() M.refresh(vim.api.nvim_get_current_buf()) end },
  { text = "Toggle unmanaged diagnostics", action = function() M.toggle_unmanaged() end }, -- settings
}

function M.palette()
  pick(PALETTE_ITEMS, "Loci palette", function(item)
    if item.action then
      item.action()
    end
  end)
end

-- ── code-action glue (vim.lsp.commands) ─────────────────────────────────────

-- The V2 adapter's actions carry `data.action_id` (+ `expected_hash` for CAS); the host adds a
-- `command: loci.action.execute` so standard clients execute them. We intercept it here to apply
-- then reload (the engine is the sole writer), and to surface refusals (D-027: `set_status`
-- refuses values that would not reparse equal) as envelope errors instead of silent success.
vim.lsp.commands["loci.action.execute"] = function(command, ctx)
  local a = (command.arguments and command.arguments[1]) or {}
  local bufnr = (ctx and ctx.bufnr) or 0
  local client = resolve_client(bufnr)
  if not client then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  local params = {
    uri = a.uri or vim.uri_from_bufnr(bufnr),
    action = {
      action_id = a.action_id,
      path = a.path,
      expected_hash = a.expected_hash,
      args = a.args or {},
    },
  }
  client:request("workspace/executeCommand", {
    command = "loci.action.execute",
    arguments = { params },
  }, function(err, result)
    if err then
      notify("action failed: " .. (err.message or "request error"), vim.log.levels.ERROR)
      return
    end
    if not (result and result.ok == true) then
      local e = (result and result.error) or {}
      notify(((e.kind and (e.kind .. ": ") or "") .. (e.message or "action failed")), vim.log.levels.ERROR)
      return
    end
    local value = result.value or {}
    if value.applied == false then
      notify("action not applied: " .. tostring(value.reason or "unknown"), vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.cmd.checktime(tostring(bufnr))
      end
    end)
  end, 0)
end

-- ── diagnostic + save-result handling ───────────────────────────────────────

-- V2 emits `unmanaged` at information for EVERY unmanaged document (D-047; 4,626 rows on the
-- representative vault). Arch §13: "Hosts may filter it out entirely by default." Filter it
-- client-side (scoped to the loci client) so the panel shows actionable diagnostics only.
-- Q3 escape hatch: a user who WANTS the informational rows sets vim.g.loci_show_unmanaged
-- (default false — the filter is unconditional today) or runs :LociToggleUnmanaged.
-- nvim pulls diagnostics (`textDocument/diagnostic`) when the host advertises diagnosticProvider,
-- so BOTH the pull handler and the push handler are wrapped.
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

local on_pull_diag = vim.lsp.handlers["textDocument/diagnostic"]
vim.lsp.handlers["textDocument/diagnostic"] = function(err, result, ctx, config)
  if not err and result and result.items and ctx and ctx.client_id then
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client and client.name == LSP_NAME then
      result.items = filter_loci_unmanaged(result.items)
    end
  end
  on_pull_diag(err, result, ctx, config)
end

local on_publish = vim.lsp.handlers["textDocument/publishDiagnostics"]
vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
  if not err and result and result.diagnostics and ctx and ctx.client_id then
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client and client.name == LSP_NAME then
      result.diagnostics = filter_loci_unmanaged(result.diagnostics)
    end
  end
  on_publish(err, result, ctx, config)
end

-- `didSave` is a notification with no response, so the host reports the CAS result back as the
-- `loci/saveResult` notification (D-041). Surface real conflicts; "unchanged" saves are silent.
-- The notification carries the `uri` of the document that was saved, so the warning NAMES the file
-- rather than leaving the user to guess which buffer conflicted — this matters precisely when it
-- fires, since a background/autosave conflict often reaches you while you are looking at a
-- different buffer. Falls back to the bare message when the host sends no uri (004 F-03: the
-- fakeserver used to omit it, so per-buffer attribution was untestable and therefore never built).
vim.lsp.handlers["loci/saveResult"] = function(err, result)
  if not result then
    return
  end
  if result.committed == false and result.reason ~= "unchanged" then
    local where = ""
    if present(result.uri) then
      local path = vim.uri_to_fname(result.uri)
      -- prefer the vault-relative path; fall back to the tail for a non-vault/unknown root
      local root = root_dir(vim.uri_to_bufnr(result.uri))
      local rel = root and path:sub(1, #root) == root and path:sub(#root + 2) or vim.fn.fnamemodify(path, ":t")
      where = " (" .. rel .. ")"
    end
    notify(
      "save not committed" .. where .. ": " .. tostring(result.reason or "conflict with an external edit"),
      vim.log.levels.WARN
    )
  end
end

-- ── user commands ───────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("LociPalette", M.palette, { desc = "Loci command palette" })
vim.api.nvim_create_user_command("LociStatus", M.status, { desc = "Loci status / workspace context" })
vim.api.nvim_create_user_command("LociWorkspaces", M.workspaces, { desc = "Loci workspaces (pin a workspace)" })
vim.api.nvim_create_user_command("LociProjects", M.projects, { desc = "Loci projects" })
vim.api.nvim_create_user_command("LociDoctor", M.doctor, { desc = "Loci vault health (refresh + graph findings)" })
vim.api.nvim_create_user_command("LociDaily", M.daily, { desc = "Loci daily note" })
vim.api.nvim_create_user_command("LociScratch", M.scratch, { desc = "Loci scratch note" })
vim.api.nvim_create_user_command("LociNote", M.new_note, { desc = "Loci new note" })
vim.api.nvim_create_user_command("LociSearch", M.search, { desc = "Loci full-text search" })
vim.api.nvim_create_user_command("LociBacklinks", M.backlinks, { desc = "Loci backlinks for the current note" })
vim.api.nvim_create_user_command("LociNeighbors", M.neighbors, { desc = "Loci graph neighbors of the current note" })
vim.api.nvim_create_user_command("LociTraversal", M.traversal, { desc = "Loci graph traversal from the current note" })
vim.api.nvim_create_user_command("LociProjectMembers", M.project_members, { desc = "Loci project members of the current note" })
vim.api.nvim_create_user_command("LociLinkFile", M.link_file, { desc = "Loci link the current file to the pinned workspace" })
vim.api.nvim_create_user_command("LociToggleUnmanaged", M.toggle_unmanaged, { desc = "Loci toggle unmanaged diagnostic rows" })
vim.api.nvim_create_user_command("LociAdopt", M.adopt, { desc = "Loci adopt the current buffer's document" })
vim.api.nvim_create_user_command("LociMove", M.move_document, { desc = "Loci move the current buffer's document" })

return M
