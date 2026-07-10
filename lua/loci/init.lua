-- loci — a thin Neovim client for the loci-core engine, spoken over the `loci-lsp` server.
--
-- CLEAN-ROOM. This file is written against the `loci-lsp` *protocol* (the wire contract: `loci/op` reads,
-- `workspace/executeCommand` effects, pushed diagnostics, code actions, and the `loci/commands` palette
-- surface). It is NOT a copy of loci-core's Lua test harness. The editor holds NO loci logic — every
-- semantic decision lives server-side in `loci_core.control.*`. The engine is the SOLE writer of co-owned
-- markdown: we never author a `WorkspaceEdit`/frontmatter here; we run an effect command and `:checktime`.
--
-- Standard LSP features are wired ELSEWHERE on purpose and must stay that way:
--   * completion  -> blink's built-in `lsp` source (do NOT call `vim.lsp.completion.enable` — double menu)
--   * code actions -> the editor's existing `<localleader>a` (`tiny-code-action`); no loci-specific keymap
--   * diagnostics  -> pushed by the server via `textDocument/publishDiagnostics`, rendered by `vim.diagnostic`
--
-- Self-initializing: `require("loci")` (no `setup()`).
--
-- The `loci-lsp` server binary is provided on PATH by nix-nvim (built from this repo's
-- flake, which re-exports loci-core's `packages.<sys>.loci-lsp`). No manual install is
-- needed in the nix fleet; the `attach()` guard below still warns if it is ever absent.

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

local function split_csv(s)
  local out = {}
  for piece in string.gmatch(s or "", "[^,]+") do
    local t = vim.trim(piece)
    if t ~= "" then
      out[#out + 1] = t
    end
  end
  return out
end

-- The loci client attached to a buffer (default: current). Reads/effects need a vault buffer.
local function client_for(bufnr)
  return vim.lsp.get_clients({ name = LSP_NAME, bufnr = bufnr or 0 })[1]
end

-- The active vault root = the attached client's root_dir (used to resolve content/linked-file paths).
local function root_dir()
  local c = vim.lsp.get_clients({ name = LSP_NAME })[1]
  return c and c.config.root_dir or nil
end

local function open_path(p)
  vim.cmd.edit(vim.fn.fnameescape(p))
end

-- Knowledge note abs path = <root>/.loci/content/<content_path>
local function open_content(content_path)
  local root = root_dir()
  if root and content_path then
    open_path(root .. "/.loci/content/" .. content_path)
  end
end

-- Linked file abs path = <root>/<path>
local function open_linked(path)
  local root = root_dir()
  if root and path then
    open_path(root .. "/" .. path)
  end
end

-- snacks-native picker over arbitrary rows; each item carries `.text` (display + match). Falls back to the
-- snacks-backed `vim.ui.select` if the picker call shape ever drifts.
local function pick(items, prompt, on_choice)
  if not items or #items == 0 then
    notify("nothing to pick", vim.log.levels.INFO)
    return
  end
  local ok = pcall(function()
    Snacks.picker.pick({
      title = prompt,
      items = items,
      -- These are action/selection rows, not files; hide the file previewer (else it errors "no `file`").
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

-- Broad attach: ANY file under a vault root attaches, so the hubs always have a live client. Buffer-anchored
-- features (completion/diagnostics/code actions) are markdown-scoped SERVER-side, so non-note buffers simply
-- receive nothing. `vim.lsp.start` dedups by (name, root_dir, cmd) -> exactly one process per vault.
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
  vim.lsp.start({ name = LSP_NAME, cmd = { "loci-lsp" }, root_dir = root }, { bufnr = bufnr })
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("loci_attach", { clear = true }),
  callback = function(args)
    attach(args.buf)
  end,
})

-- Minimal LspAttach: completion is blink's `lsp` source and code actions are the global `<localleader>a`, so
-- there is no per-buffer loci wiring beyond a marker for discoverability. Do NOT enable `vim.lsp.completion`.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("loci_lsp_attach", { clear = true }),
  callback = function(args)
    local c = vim.lsp.get_client_by_id(args.data.client_id)
    if c and c.name == LSP_NAME then
      vim.b[args.buf].loci_attached = true
    end
  end,
})

-- ── request primitives ──────────────────────────────────────────────────────

-- Default-deny READ over `loci/op` -> the `{ ok, error }` envelope's `value` (or a surfaced error notify).
function M.read(op, args, cb)
  local client = client_for(0)
  if not client then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  client:request("loci/op", { op = op, args = args or vim.empty_dict() }, function(err, result)
    if err then
      notify(op .. " failed: " .. (err.message or "request error"), vim.log.levels.ERROR)
      return
    end
    if not (result and result.ok == true) then
      local e = (result and result.error) or {}
      notify(op .. ": " .. (e.message or "error"), vim.log.levels.ERROR)
      return
    end
    cb(result.value)
  end, 0)
end

-- EFFECT over `workspace/executeCommand` (single JSON-object argument) -> the `{ ok, error }` envelope.
function M.command(name, args, cb)
  local client = client_for(0)
  if not client then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  client:request("workspace/executeCommand", {
    command = name,
    arguments = { args or vim.empty_dict() },
  }, function(err, result)
    if err then
      notify(name .. " failed: " .. (err.message or "request error"), vim.log.levels.ERROR)
      return
    end
    if not (result and result.ok == true) then
      local e = (result and result.error) or {}
      notify(name .. ": " .. (e.message or "error"), vim.log.levels.ERROR)
      return
    end
    if cb then
      cb(result.value)
    end
  end, 0)
end

-- Run an effect, then reload the buffer (the engine is the sole writer). `:checktime` won't clobber unsaved.
local function apply_and_reload(name, args)
  M.command(name, args, function()
    vim.schedule(function()
      vim.cmd("checktime")
    end)
  end)
end

-- Render a single projected field value (vim.NIL-safe): lists join, tables inspect compactly, `nil`/null -> —.
local function fmt_val(v)
  if not present(v) then
    return "—"
  end
  if type(v) == "table" then
    if vim.islist(v) then
      return #v == 0 and "[]" or table.concat(vim.tbl_map(tostring, v), ", ")
    end
    return vim.inspect(v, { newline = " ", indent = "" })
  end
  return tostring(v)
end

-- Turn the engine's dry-run `value` into human lines showing WHAT would change. We surface the engine's OWN
-- returned projection (never author a diff): `note.update`'s before/after, `project.link`'s would-be
-- `projects` list, else a compact scalar dump of the non-bookkeeping fields.
local function summarize_dry_run(value)
  if not present(value) then
    return {}
  end
  local lines = {}
  if present(value.before) and present(value.after) then
    if value.changed == false then
      lines[#lines + 1] = "(no changes)"
    else
      local keys = vim.tbl_keys(value.after)
      table.sort(keys)
      for _, k in ipairs(keys) do
        local b, a = value.before[k], value.after[k]
        if fmt_val(b) ~= fmt_val(a) then
          lines[#lines + 1] = string.format("%s: %s → %s", k, fmt_val(b), fmt_val(a))
        end
      end
    end
  elseif present(value.projects) then
    lines[#lines + 1] = "projects → " .. fmt_val(value.projects)
  else
    local skip = { dry_run = true, applied = true, loci_id = true, content_path = true }
    local keys = {}
    for k in pairs(value) do
      if not skip[k] then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      lines[#lines + 1] = string.format("%s: %s", k, fmt_val(value[k]))
    end
  end
  return lines
end

-- Dry-run -> confirm -> apply (sole-writer-safe preview for contextual writes invoked outside a code action).
-- The confirm prompt renders the engine's projected result so the user sees WHAT changes before applying.
local function preview_then_apply(name, args, describe)
  local dry = vim.tbl_extend("force", args or {}, { dry_run = true })
  M.command(name, dry, function(value)
    vim.schedule(function()
      local header = (describe and describe(value)) or (name .. " — apply?")
      local lines = summarize_dry_run(value)
      local prompt = (#lines > 0) and (header .. "\n" .. table.concat(lines, "\n")) or header
      vim.ui.select({ "Apply", "Cancel" }, { prompt = prompt }, function(choice)
        if choice == "Apply" then
          apply_and_reload(name, args)
        end
      end)
    end)
  end)
end

-- ── activation + editor_state applier ───────────────────────────────────────

-- Apply each present `editor_state` block; every plugin call is pcall-guarded so a missing plugin no-ops.
local function apply_editor_state(es)
  if not present(es) then
    return
  end

  local git = es.git
  if present(git) and present(git.worktree_path) then
    pcall(vim.cmd.tcd, git.worktree_path)
  end

  local haunt = es.haunt
  if present(haunt) and present(haunt.data_dir) then
    pcall(function()
      require("haunt.api").change_data_dir(haunt.data_dir)
    end)
  end

  local resession = es.resession
  if present(resession) and present(resession.session_name) then
    pcall(function()
      require("resession").load(resession.session_name, { silence_errors = true })
    end)
  end

  local wayfinder = es.wayfinder
  if present(wayfinder) and present(wayfinder.trail_name) then
    pcall(function()
      require("wayfinder").trail_load_named(wayfinder.trail_name)
    end)
  end

  -- es.tabby.label is presentational; the editor owns the live tab id. Skip.
end

-- Activate a workspace: apply the engine's editor_state plan, mark the tab, then observe + persist the git
-- branch/worktree the editor actually checked out (the engine omits `git` on activate — editor-observed).
function M.activate(workspace_id)
  if not workspace_id then
    return
  end
  M.command("loci.workspace.activate", { workspace_id = workspace_id }, function(value)
    vim.schedule(function()
      if value and present(value.editor_state) then
        apply_editor_state(value.editor_state)
      end
      vim.t.loci_workspace_id = workspace_id
      vim.cmd("checktime")
      local out = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
      local branch = out and out[1]
      if vim.v.shell_error == 0 and branch and branch ~= "" then
        M.command("loci.workspace.set_editor_state", {
          workspace_id = workspace_id,
          git = { branch = branch, worktree_path = vim.fn.getcwd() },
        })
      end
      notify("workspace activated")
    end)
  end)
end

-- ── client-command glue (vim.lsp.commands) ──────────────────────────────────
--
-- A code action whose `.command` is present in `vim.lsp.commands` runs the Lua handler instead of being sent
-- as `executeCommand`. Two roles: (1) intercept the server's WRITE commands so the buffer reloads after the
-- engine writes; (2) resolve client-only choices (pickers/prompts) the server can't enumerate. Each handler
-- receives the LSP `Command` table `{ title, command, arguments }`.

-- (1) apply-then-reload: run the write `executeCommand`, then `:checktime`.
for _, name in ipairs({
  "loci.note.update",
  "loci.note.adopt",
  "loci.knowledge.add",
  "loci.knowledge.set_primary",
  "loci.knowledge.remove",
  "loci.linked_files.unlink",
}) do
  vim.lsp.commands[name] = function(command)
    local a = (command.arguments and command.arguments[1]) or {}
    apply_and_reload(command.command, a)
  end
end

-- (2) pick_tags: free-form comma-separated tag set (known values hinted) -> dry-run preview + note.update.
vim.lsp.commands["loci.pick_tags"] = function(command)
  local a = (command.arguments and command.arguments[1]) or {}
  local content_path = a.content_path
  M.read("field_values", { key = "tags" }, function(value)
    vim.schedule(function()
      local known = {}
      for _, p in ipairs(value or {}) do
        known[#known + 1] = (type(p) == "table" and (p.value or p.label)) or p
      end
      local hint = (#known > 0) and (" [known: " .. table.concat(known, ", ") .. "]") or ""
      vim.ui.input({ prompt = "Tags (comma-separated)" .. hint .. ": " }, function(input)
        if not input then
          return
        end
        local tags = split_csv(input)
        preview_then_apply("loci.note.update", { content_path = content_path, tags = tags }, function()
          return "Set tags: " .. table.concat(tags, ", ")
        end)
      end)
    end)
  end)
end

-- (2) pick_project: choose a project -> dry-run preview + project.link.
vim.lsp.commands["loci.pick_project"] = function(command)
  local a = (command.arguments and command.arguments[1]) or {}
  local content_path = a.content_path
  M.read("project.index", {}, function(rows)
    vim.schedule(function()
      local items = {}
      for _, p in ipairs(rows or {}) do
        items[#items + 1] = {
          text = (p.title or p.project_id) .. " (" .. (p.status or "") .. ")",
          project_id = p.project_id,
          title = p.title,
        }
      end
      pick(items, "Link to project", function(item)
        preview_then_apply(
          "loci.project.link",
          { content_path = content_path, project_id = item.project_id },
          function()
            return "Link to project: " .. (item.title or item.project_id)
          end
        )
      end)
    end)
  end)
end

-- (2) pick_workspace: arg { op, args } — choose a workspace, apply `loci.<op>` with workspace_id merged in.
vim.lsp.commands["loci.pick_workspace"] = function(command)
  local a = (command.arguments and command.arguments[1]) or {}
  local op = a.op
  local base = a.args or {}
  M.read("workspace.index", {}, function(rows)
    vim.schedule(function()
      local items = {}
      for _, w in ipairs(rows or {}) do
        items[#items + 1] = {
          text = w.name .. (w.archived and " (archived)" or ""),
          workspace_id = w.workspace_id,
        }
      end
      pick(items, "Select workspace", function(item)
        local args = vim.tbl_extend("force", base, { workspace_id = item.workspace_id })
        apply_and_reload("loci." .. op, args)
      end)
    end)
  end)
end

-- (2) link_file: arg { path, workspace_id? } — pick a role (and a workspace if not baked) -> linked_files.link.
vim.lsp.commands["loci.link_file"] = function(command)
  local a = (command.arguments and command.arguments[1]) or {}
  local path = a.path
  local roles = { "implementation", "reference", "related", "documentation", "test" }

  local function with_workspace(workspace_id)
    vim.ui.select(roles, { prompt = "Role:" }, function(role)
      if not role then
        return
      end
      apply_and_reload("loci.linked_files.link", { path = path, workspace_id = workspace_id, role = role })
    end)
  end

  if present(a.workspace_id) then
    vim.schedule(function()
      with_workspace(a.workspace_id)
    end)
  else
    M.read("workspace.index", {}, function(rows)
      vim.schedule(function()
        local items = {}
        for _, w in ipairs(rows or {}) do
          items[#items + 1] = {
            text = w.name .. (w.archived and " (archived)" or ""),
            workspace_id = w.workspace_id,
          }
        end
        pick(items, "Link to workspace", function(item)
          with_workspace(item.workspace_id)
        end)
      end)
    end)
  end
end

-- ── hubs ────────────────────────────────────────────────────────────────────

-- Prompt the palette command's args one at a time, by `kind`, then call `done(collected)`. A cancelled
-- REQUIRED arg aborts the whole command (never call `done`); a cancelled optional arg is simply omitted.
local function prompt_args(specs, done)
  local collected = {}
  local i = 1
  local function step()
    local spec = specs[i]
    if not spec then
      done(collected)
      return
    end
    i = i + 1
    local function continue(val)
      if val ~= nil then
        collected[spec.name] = val
      end
      step()
    end
    local label = spec.name .. (spec.required and "" or " (optional)")
    if spec.kind == "bool" then
      vim.ui.select({ "true", "false" }, { prompt = label .. ":" }, function(c)
        if c == nil then
          if spec.required then
            return
          end
          return continue(nil)
        end
        continue(c == "true")
      end)
    elseif spec.kind == "vocab" then
      vim.ui.select(spec.values or {}, { prompt = label .. ":" }, function(c)
        if c == nil and spec.required then
          return
        end
        continue(c)
      end)
    elseif spec.kind == "list" then
      vim.ui.input({ prompt = label .. " (comma-separated): " }, function(input)
        if input == nil then
          if spec.required then
            return
          end
          return continue(nil)
        end
        continue(split_csv(input))
      end)
    else -- string
      vim.ui.input({ prompt = label .. ": " }, function(input)
        if input == nil or input == "" then
          if spec.required then
            return
          end
          return continue(nil)
        end
        continue(input)
      end)
    end
  end
  step()
end

-- Run a palette command with collected args. The activation flows apply editor_state; everything else just
-- reloads the buffer after the write.
local function run_palette(command, args)
  if command == "loci.workspace.activate" then
    M.activate(args.workspace_id)
  elseif command == "loci.start-work" then
    M.command(command, args, function(value)
      vim.schedule(function()
        if value and present(value.editor_state) then
          apply_editor_state(value.editor_state)
        end
        vim.cmd("checktime")
        notify("started work")
      end)
    end)
  else
    apply_and_reload(command, args)
  end
end

-- Command palette: snacks pick over `loci/commands`, prompt each arg by kind, fire the executeCommand.
function M.palette()
  local client = client_for(0)
  if not client then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  client:request("loci/commands", vim.empty_dict(), function(err, result)
    if err or not result then
      notify("palette unavailable: " .. ((err and err.message) or "no response"), vim.log.levels.ERROR)
      return
    end
    vim.schedule(function()
      local items = {}
      for _, c in ipairs(result.commands or {}) do
        items[#items + 1] = { text = c.title, command = c.command, args = c.args or {} }
      end
      pick(items, "Loci palette", function(item)
        prompt_args(item.args, function(collected)
          run_palette(item.command, collected)
        end)
      end)
    end)
  end, 0)
end

-- Pick a file under the vault and link it to the workspace via the existing `loci.link_file` glue (which
-- asks the role, then applies `linked_files.link`). The glue + engine format-check the (repo-relative) path,
-- so a best-effort relativize is enough — a bad path surfaces as a clean envelope error.
local function link_file_flow(workspace_id)
  local root = root_dir()
  local function do_link(rel)
    if not rel or rel == "" then
      return
    end
    vim.lsp.commands["loci.link_file"]({ arguments = { { path = rel, workspace_id = workspace_id } } })
  end
  local function relativize(p)
    if root and p and p:sub(1, #root + 1) == (root .. "/") then
      return p:sub(#root + 2)
    end
    return p
  end
  local ok = pcall(function()
    Snacks.picker.files({
      cwd = root,
      confirm = function(picker, item)
        picker:close()
        if item then
          do_link(relativize(item.file or item.text))
        end
      end,
    })
  end)
  if not ok then
    vim.ui.input({ prompt = "Link file (vault-relative path): " }, function(input)
      do_link(input and vim.trim(input))
    end)
  end
end

-- Status / context hub: the active workspace (+ its project context), knowledge notes and linked files
-- (open / unlink), plus link-a-file, reconcile, and deactivate verbs. Every row either opens a file or runs a
-- single verb (house style: flat rows + closures, no nested menus).
function M.status()
  M.read("workspace.current", {}, function(cur)
    if not (cur and cur.found == true) then
      vim.schedule(function()
        notify("no active workspace — use <leader>lw to switch")
      end)
      return
    end
    local wid = cur.workspace_id
    M.read("workspace.summary", { workspace_id = wid }, function(sum)
      M.read("workspace.get", { workspace_id = wid }, function(ws)
        local function show(project, member_count)
          vim.schedule(function()
            local rows = {}
            rows[#rows + 1] = {
              text = string.format(
                "● %s  [%d notes · %d files]",
                (sum and sum.name) or wid,
                (sum and sum.knowledge_count) or 0,
                (sum and sum.linked_file_count) or 0
              ),
              action = function() end,
            }
            if present(project) then
              local cp = project.content_path
              local count = member_count and (" · " .. member_count .. " members") or ""
              rows[#rows + 1] = {
                text = string.format("  ◆ project: %s (%s)%s", project.title or "?", project.status or "?", count),
                action = function()
                  open_content(cp)
                end,
              }
            end
            local objects = (ws and ws.knowledge and ws.knowledge.objects) or {}
            for _, o in ipairs(objects) do
              local cp = o.content_path
              rows[#rows + 1] = {
                text = "  note  " .. (o.title_cache or cp),
                action = function()
                  open_content(cp)
                end,
              }
            end
            for _, lf in ipairs((ws and ws.linked_files) or {}) do
              local p = lf.path
              rows[#rows + 1] = {
                text = "  file  " .. p .. " (" .. (lf.role or "") .. ")",
                action = function()
                  open_linked(p)
                end,
              }
              rows[#rows + 1] = {
                text = "    ▸ unlink " .. p,
                action = function()
                  apply_and_reload("loci.linked_files.unlink", { workspace_id = wid, path = p })
                end,
              }
            end
            rows[#rows + 1] = {
              text = "  ▸ link a file to this workspace…",
              action = function()
                link_file_flow(wid)
              end,
            }
            rows[#rows + 1] = {
              text = "  ▸ reconcile workspace",
              action = function()
                apply_and_reload("loci.reconcile", {})
              end,
            }
            rows[#rows + 1] = {
              text = "  ▸ deactivate workspace",
              action = function()
                apply_and_reload("loci.workspace.deactivate", { workspace_id = wid })
              end,
            }
            pick(rows, "Loci status", function(item)
              if item.action then
                item.action()
              end
            end)
          end)
        end

        if present(cur.project_id) then
          M.read("project.get", { project_id = cur.project_id }, function(proj)
            M.read("project.members", { project_id = cur.project_id }, function(mem)
              show(proj, mem and mem.members and #mem.members or nil)
            end)
          end)
        else
          show(nil, nil)
        end
      end)
    end)
  end)
end

-- Workspace switcher: pick from `workspace.index` -> activate (closes GAP-2).
function M.workspaces()
  M.read("workspace.index", {}, function(rows)
    vim.schedule(function()
      local items = {}
      for _, w in ipairs(rows or {}) do
        items[#items + 1] = {
          text = w.name .. (w.archived and " (archived)" or ""),
          workspace_id = w.workspace_id,
        }
      end
      pick(items, "Switch workspace", function(item)
        M.activate(item.workspace_id)
      end)
    end)
  end)
end

-- Project picker: pick from `project.index` -> open the project note (closes GAP-1).
function M.projects()
  M.read("project.index", {}, function(rows)
    vim.schedule(function()
      local items = {}
      for _, p in ipairs(rows or {}) do
        items[#items + 1] = {
          text = (p.title or p.project_id) .. " (" .. (p.status or "") .. ")",
          content_path = p.content_path,
        }
      end
      pick(items, "Projects", function(item)
        open_content(item.content_path)
      end)
    end)
  end)
end

-- Doctor hub: the whole-vault `doctor` report. Each row is a finding (confirm opens its file); a top row
-- bulk-fixes the safe `missing_loci_id` subset via `loci.doctor_fix` (the only fixer the engine offers today —
-- a per-code chooser waits on more engine fixers). The report is `{ issues, ok, stats }`; findings live under
-- `value.issues`, the fixable count under `value.stats.by_code.missing_loci_id`.
function M.doctor()
  M.read("doctor", {}, function(report)
    vim.schedule(function()
      local issues = (report and report.issues) or {}
      if #issues == 0 then
        notify("doctor: vault clean")
        return
      end
      local rows = {}
      local stats = (report and report.stats) or {}
      local fixable = (present(stats.by_code) and stats.by_code.missing_loci_id) or 0
      if fixable > 0 then
        rows[#rows + 1] = {
          text = string.format("▸ Fix all missing loci_id (%d)", fixable),
          action = function()
            apply_and_reload("loci.doctor_fix", {})
          end,
        }
      end
      for _, f in ipairs(issues) do
        local path = present(f.path) and f.path or "(vault)"
        rows[#rows + 1] = {
          text = string.format("[%s] %s — %s", f.code, path, f.message),
          action = present(f.path) and function()
            open_content(f.path)
          end or nil,
        }
      end
      pick(rows, "Loci doctor", function(item)
        if item.action then
          item.action()
        end
      end)
    end)
  end)
end

-- ── note quick-commands ──────────────────────────────────────────────────────
--
-- The three note effects (already in the palette) given direct verbs. Each returns the new note record whose
-- `content_path` we open under <root>/.loci/content/ (confirmed live: the field is `content_path`).

local function open_new_note(value)
  if value and present(value.content_path) then
    open_content(value.content_path)
  end
end

function M.daily()
  M.command("loci.note.daily", {}, function(value)
    vim.schedule(function()
      open_new_note(value)
    end)
  end)
end

function M.scratch()
  M.command("loci.note.scratch", {}, function(value)
    vim.schedule(function()
      open_new_note(value)
    end)
  end)
end

-- New note: reuse the palette's per-kind arg-prompt flow over `note.create`'s LIVE spec (from `loci/commands`),
-- then create + open — so the prompted args track whatever the engine declares, no hardcoding here.
function M.new_note()
  local client = client_for(0)
  if not client then
    notify("open a file inside a loci vault", vim.log.levels.WARN)
    return
  end
  client:request("loci/commands", vim.empty_dict(), function(err, result)
    if err or not result then
      notify("note.create unavailable: " .. ((err and err.message) or "no response"), vim.log.levels.ERROR)
      return
    end
    local spec
    for _, c in ipairs(result.commands or {}) do
      if c.command == "loci.note.create" then
        spec = c
        break
      end
    end
    if not spec then
      notify("note.create not offered by the server", vim.log.levels.ERROR)
      return
    end
    vim.schedule(function()
      prompt_args(spec.args or {}, function(collected)
        M.command("loci.note.create", collected, function(value)
          vim.schedule(function()
            open_new_note(value)
          end)
        end)
      end)
    end)
  end, 0)
end

-- ── user commands ───────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("LociPalette", M.palette, { desc = "Loci command palette" })
vim.api.nvim_create_user_command("LociStatus", M.status, { desc = "Loci status / context hub" })
vim.api.nvim_create_user_command("LociWorkspaces", M.workspaces, { desc = "Loci switch workspace" })
vim.api.nvim_create_user_command("LociProjects", M.projects, { desc = "Loci projects" })
vim.api.nvim_create_user_command("LociDoctor", M.doctor, { desc = "Loci doctor (findings)" })
vim.api.nvim_create_user_command("LociDaily", M.daily, { desc = "Loci daily note" })
vim.api.nvim_create_user_command("LociScratch", M.scratch, { desc = "Loci scratch note" })
vim.api.nvim_create_user_command("LociNote", M.new_note, { desc = "Loci new note" })

return M
