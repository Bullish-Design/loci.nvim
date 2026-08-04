-- t02 — no-client warn: a `:Loci*` flow on a file outside any vault warns "open a
-- file inside a loci vault" (not "server still starting" — no server exists).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

local outside = c.work .. "/outside.txt"
vim.cmd("edit " .. vim.fn.fnameescape(outside))
vim.wait(300)
local ok, err = pcall(function()
  loci.status()
end)
c.expect(ok, "status with no client must not crash: " .. tostring(err))
c.expect(c.any_notice("open a file inside a loci vault"), "expected the no-client warn")
c.expect(not c.any_notice("server still starting"), "no server exists — must not say 'starting'")
c.finish()
