-- t16 — create a workspace: `workspaces/put` is previewed (its declared pure
-- route), applied on confirm, and the created workspace becomes the tab pin.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

vim.env.PICK_MATCH = "create workspace"
vim.ui.input = function(_, cb)
  cb("New WS")
end
vim.ui.select = function(items, _, cb)
  cb(items[1]) -- "Apply"
end
loci.workspaces()
local created = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/workspaces/put/preview", 1, true) ~= nil
    and l:find("req loci/workspaces/put", 1, true) ~= nil
    and l:find("New WS", 1, true) ~= nil
end, 4000)
c.expect(created, "create-workspace should preview then apply workspaces/put with the name")
local pinned = c.wait_for(function()
  return vim.t.loci_workspace_id == "ws-2"
end, 2000)
c.expect(pinned, "the created workspace (ws-2 from the fake) should become the tab pin")
c.expect(not c.any_notice("failed"), "a clean put must not surface errors")
c.finish()
