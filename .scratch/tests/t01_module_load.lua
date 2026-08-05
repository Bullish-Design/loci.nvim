-- t01 — module load: require("loci") self-initializes and registers the 10 user
-- commands, with no client spawned before a vault file is opened.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
local cmds = vim.api.nvim_get_commands({})
local lower = {}
for k in pairs(cmds) do
  lower[k:lower()] = true
end
local expected = {
  "locipalette", "locistatus", "lociworkspaces", "lociprojects", "locidoctor",
  "locidaily", "lociscratch", "locinote", "locisearch", "locibacklinks",
}
for _, name in ipairs(expected) do
  c.expect(lower[name] == true, "user command missing: " .. name)
end
local clients = vim.lsp.get_clients({ name = "loci" })
c.expect(#clients == 0, "no client should exist before a vault file is opened")
c.finish()
