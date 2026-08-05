-- t11 — code-action dispatch (V2): actions carry `data.action_id` and a
-- `command: loci.action.execute`; executing via client:exec_cmd (the fleet's
-- tiny-code-action path) must hit the client's interception, send
-- `workspace/executeCommand` back, and surface refusals as envelope errors.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

local bufnr = vim.api.nvim_get_current_buf()
local client = vim.lsp.get_clients({ name = "loci", bufnr = bufnr })[1]
c.expect(client ~= nil, "loci client should be attached")

local actions = {}
client:request("textDocument/codeAction", {
  textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
  context = { diagnostics = {} },
}, function(err, result)
  if not err then
    actions = result or {}
  end
end)
local got_action = c.wait_for(function()
  return #actions > 0
end, 3000)
c.expect(got_action, "server should advertise a code action")
c.expect(actions[1] and actions[1].command and actions[1].command.command == "loci.action.execute",
  "action should carry the loci.action.execute command for exec_cmd")

if actions[1] and actions[1].command then
  client:exec_cmd(actions[1].command, { bufnr = bufnr })
end
local applied = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("loci.action.execute", 1, true) ~= nil
end, 3000)
c.expect(applied, "exec_cmd interception should reach the server as loci.action.execute")
local log = c.read_file(c.work .. "/logA") or ""
c.expect(log:find("documents.set_status", 1, true) ~= nil, "action should carry action_id documents.set_status: " .. log)
c.expect(not c.any_notice("failed"), "a clean action must not surface errors")
c.finish()
