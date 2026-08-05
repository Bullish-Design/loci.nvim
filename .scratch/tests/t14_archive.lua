-- t14 — archive from the status hub: the row previews `workspaces/archive`
-- (the feature's DECLARED pure preview route, D-032) then applies it on confirm.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

vim.t.loci_workspace_id = "ws-1"
vim.env.PICK_MATCH = "archive workspace"
vim.ui.select = function(items, _, cb)
  cb(items[1]) -- "Apply"
end
loci.status()
local applied = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/workspaces/archive/preview", 1, true) ~= nil
    and l:find("req loci/workspaces/archive", 1, true) ~= nil
end, 4000)
c.expect(applied, "archive should preview then apply (both requests must reach the server)")
c.expect(not c.any_notice("failed"), "a clean archive must not surface errors")
c.finish()
