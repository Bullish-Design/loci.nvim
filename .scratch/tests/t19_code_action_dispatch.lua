-- t19 — code-action dispatch through client:exec_cmd (the fleet's
-- tiny-code-action@0d040ed path, backend="vim", picker="snacks"): nvim 0.12's
-- exec_cmd resolves vim.lsp.commands FIRST, so the client's write-command
-- interception (apply-then-reload) and the client-only picker commands fire.
-- Discriminator: fs_index advertises NO executeCommandProvider, so nvim's own
-- fall-through would warn + drop; a command that reaches the server can only
-- have come from the client's intercepted Lua handler.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

-- the pick_project flow ends in preview_then_apply's dry-run confirm
-- (vim.ui.select) — headless that blocks on stdin, so stub the UI callbacks
vim.ui.select = function(items, opts, cb)
  cb(items and items[1])
end
vim.ui.input = function(opts, cb)
  cb("")
end

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local buf = vim.api.nvim_get_current_buf()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_index.py", c.work .. "/logA")
vim.wait(1000)
local client = vim.lsp.get_clients({ name = "loci" })[1]
c.expect(client ~= nil, "fake client should be attached")
if not client then
  c.finish()
  return
end

-- (1) WRITE command: exec_cmd must dispatch to the client's apply-then-reload
-- handler (vim.lsp.commands[\"loci.note.update\"]), which sends the effect.
client:exec_cmd({ command = "loci.note.update", arguments = { { content_path = "notes/a.md" } } }, {})
vim.wait(1200)
local log = c.read_file(c.work .. "/logA") or ""
c.expect(
  log:find("note.update", 1, true) ~= nil,
  "write command must reach the server via the intercepted handler (not nvim's drop): " .. log
)

-- (2) client-only command: exec_cmd must dispatch to the Lua handler, whose
-- read hits the server.
client:exec_cmd({ command = "loci.pick_project", arguments = { { content_path = "notes/a.md" } } }, {})
vim.wait(1200)
log = c.read_file(c.work .. "/logA") or ""
c.expect(
  log:find("project.index", 1, true) ~= nil,
  "client-only command must reach its Lua handler (read hits the server): " .. log
)

-- (3) ctx.bufnr pinning: exec_cmd resolves a nil ctx.bufnr to the invocation
-- buffer (vim._resolve_bufnr(nil) -> current buffer; the picker restores the
-- window to the original buffer before exec_cmd, so current == original).
local ctx_bufnr
vim.lsp.commands["loci.test.ctx"] = function(cmd, ctx)
  ctx_bufnr = ctx and ctx.bufnr
end
client:exec_cmd({ command = "loci.test.ctx", arguments = {} }, {})
c.expect(
  ctx_bufnr == buf,
  "exec_cmd must resolve ctx.bufnr to the invocation buffer, got " .. tostring(ctx_bufnr)
)
c.finish()
