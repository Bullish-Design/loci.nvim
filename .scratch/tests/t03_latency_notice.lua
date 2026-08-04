-- t03 — attach-latency UX: while the only loci client is still initializing, a
-- `:Loci*` read must say "server still starting" instead of "open a file inside a
-- loci vault" (Task 3a).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_slow.py", "3000")

-- still inside the initialize window: the read must name the latency, not the file
vim.wait(400)
loci.daily()
vim.wait(300)
c.expect(c.any_notice("server still starting"), "expected 'server still starting' while initializing")
c.expect(not c.any_notice("open a file inside a loci vault"), "must NOT say 'open a file in a vault' while initializing")

-- once initialize completes, the same read reaches the server (no false message)
local ready = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 6000)
c.expect(ready, "the fake server should finish initializing")
c.finish()
