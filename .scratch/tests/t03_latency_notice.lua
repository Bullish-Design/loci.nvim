-- t03 — attach-latency UX: while the only loci client is still initializing, a
-- read must say "server still starting" instead of "open a file inside a loci
-- vault".
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_slow.py", "3000")
local reached = false
loci.read("documents/list", {}, function()
  reached = true
end)
vim.wait(800)
c.expect(reached == false, "read should not complete while initialize is pending")
c.expect(c.any_notice("server still starting"), "should say the server is still starting")
c.finish()
