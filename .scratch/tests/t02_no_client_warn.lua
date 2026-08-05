-- t02 — no-client warn: a read on a file outside any vault warns "open a file
-- inside a loci vault" (not "server still starting" — no server exists).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
local outside = c.work .. "/outside.txt"
vim.cmd("edit " .. vim.fn.fnameescape(outside))
vim.wait(300)
local reached = false
loci.read("documents/list", {}, function()
  reached = true
end)
vim.wait(300)
c.expect(reached == false, "no read should reach a server when there is no client")
c.expect(c.any_notice("open a file inside a loci vault"), "should warn about a missing vault client")
c.expect(not c.any_notice("server still starting"), "must NOT claim the server is starting")
c.finish()
