-- t16 — F9 server-death hygiene through the REAL attach() autocmd (the fakeserver
-- is reached via a `loci-lsp` shim on PATH, so the client's own on_error/on_exit
-- handlers — which only attach() registers — are what the assertions exercise):
-- a graceful stop is silent and clears the stale tab marker; a force-kill
-- surfaces the recovery hint and still clears the marker.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

-- a `.loci/` marker dir is what the attach autocmd looks for (both vaults)
vim.fn.mkdir(c.repo_b .. "/.loci", "p")
vim.fn.mkdir(c.repo_a .. "/.loci", "p")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 6000)
c.expect(attached, "attach() should spawn the shimmed fake server")
if not attached then
  c.finish()
  return
end

-- graceful stop: marker clears, no recovery hint (silent on normal quit)
vim.t.loci_workspace_id = "ws-1"
local client = vim.lsp.get_clients({ name = "loci" })[1]
client:stop()
vim.wait(1500)
c.expect(vim.t.loci_workspace_id == nil, "marker must clear on client exit (F9)")
c.expect(not c.any_notice("exited"), "graceful stop must be silent")

-- force-kill via the server dying abnormally (nonzero exit mid-request): the
-- client's on_exit must clear the marker + surface the recovery hint
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local reattached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 6000)
c.expect(reattached, "attach() should re-spawn after the first stop")
if not reattached then
  c.finish()
  return
end
vim.t.loci_workspace_id = "ws-2"
local client2 = vim.lsp.get_clients({ name = "loci" })[1]
client2:request("workspace/executeCommand", { command = "loci.test.crash", arguments = {} }, function() end)
vim.wait(1500)
c.expect(vim.t.loci_workspace_id == nil, "marker must clear on abnormal exit (F9)")
c.expect(c.any_notice("exited"), "abnormal exit should surface a recovery hint")
c.finish()
