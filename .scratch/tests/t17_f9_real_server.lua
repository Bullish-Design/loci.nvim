-- t17 — F9 end-to-end with the REAL loci-lsp: the attach autocmd spawns the real
-- server (~4s initialize) and both exit flavors clear the tab marker — graceful
-- stop silently, SIGTERM (nvim's force-stop) also silently (signal 15 is the
-- designed-silent set). The abnormal-exit recovery HINT is exercised
-- deterministically in t16 (the fake dies with exit code 3).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

-- the runner puts a `loci-lsp` shim (fake server) first on PATH for t16; this
-- test wants the REAL binary, so drop the sandbox bin dir from PATH first
vim.env.PATH = vim.env.PATH:gsub("^" .. vim.pesc(c.work .. "/bin:") , "")

-- a `.loci/` marker dir is what the attach autocmd looks for
vim.fn.mkdir(c.repo_b .. "/.loci", "p")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))

local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 12000)
c.expect(attached, "real loci-lsp should attach within 12s")
if not attached then
  c.finish()
  return
end

-- graceful stop: marker clears, no recovery hint (silent on normal quit)
vim.t.loci_workspace_id = "ws-1"
local client = vim.lsp.get_clients({ name = "loci" })[1]
client:stop()
vim.wait(2000)
c.expect(vim.t.loci_workspace_id == nil, "marker must clear on client exit (F9)")
c.expect(not c.any_notice("exited"), "graceful stop must be silent")

-- force stop (SIGTERM): still silent by design (signal 15), marker still clears
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/f.txt"))
local reattached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 12000)
c.expect(reattached, "attach() should re-spawn after the first stop")
if not reattached then
  c.finish()
  return
end
vim.t.loci_workspace_id = "ws-2"
local client2 = vim.lsp.get_clients({ name = "loci" })[1]
client2:stop(true)
vim.wait(2000)
c.expect(vim.t.loci_workspace_id == nil, "marker must clear on force-stop (F9)")
c.expect(not c.any_notice("exited"), "SIGTERM force-stop is the designed-silent set")
c.finish()
