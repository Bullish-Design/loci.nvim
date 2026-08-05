-- t15 — server-death hygiene through the REAL attach() autocmd (the `loci-lsp`
-- shim on PATH execs fs_v2.py): an abnormal exit (fake dies with code 3
-- mid-request) surfaces the recovery hint and clears the stale tab marker.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
-- a REAL initialized vault (manifest present) so attach() spawns the server
vim.fn.mkdir(c.repo_b .. "/.loci", "p")
local vt = io.open(c.repo_b .. "/.loci/vault.toml", "w")
vt:write("schema = 1\n")
vt:close()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 8000)
c.expect(attached, "attach() should spawn the shim fake and initialize")

vim.t.loci_workspace_id = "ws-9"
local client = vim.lsp.get_clients({ name = "loci" })[1]
client:request("workspace/executeCommand", { command = "loci.test.crash", arguments = {} }, function() end)
local cleared = c.wait_for(function()
  return vim.t.loci_workspace_id == nil
end, 6000)
c.expect(cleared, "an abnormal exit must clear the stale tab marker")
c.expect(c.any_notice("exited"), "an abnormal exit must surface the recovery hint")
c.finish()
