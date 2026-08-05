-- t05 — workspace switcher (V2): `workspaces/list` -> pick -> pin as the TAB's
-- workspace (no engine activation — arch §6.7) -> status hub reads
-- `workspaces/get`.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

loci.workspaces()
local got_pin = c.wait_for(function()
  return vim.t.loci_workspace_id == "ws-1"
end, 4000)
c.expect(got_pin, "picking a workspace should pin vim.t.loci_workspace_id to ws-1")

local log = c.read_file(c.work .. "/logA") or ""
local got_list = c.wait_for(function()
  return (c.read_file(c.work .. "/logA") or ""):find("req loci/workspaces/list", 1, true) ~= nil
end, 3000)
c.expect(got_list, "workspaces/list should reach the server: " .. log)
local got_get = c.wait_for(function()
  return (c.read_file(c.work .. "/logA") or ""):find("req loci/workspaces/get", 1, true) ~= nil
end, 3000)
c.expect(got_get, "status hub should read workspaces/get after pinning: " .. log)
c.finish()
