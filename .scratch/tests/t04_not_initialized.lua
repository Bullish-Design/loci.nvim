-- t04 — vault-not-initialized: a `.loci/` directory WITHOUT a `vault.toml`
-- (V2 requires the manifest; `Loci.open` raises VaultNotInitialized) must refuse
-- to attach with a one-time warning — the client never spawns a doomed server.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.fn.mkdir(c.repo_b .. "/.loci", "p")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
vim.wait(800)
local clients = vim.lsp.get_clients({ name = "loci" })
c.expect(#clients == 0, "no client should attach to an uninitialized vault")
c.expect(c.any_notice("not initialized"), "should warn that the vault is not initialized")
c.expect(c.any_notice("vault.toml"), "warning should name the missing manifest")
c.finish()
