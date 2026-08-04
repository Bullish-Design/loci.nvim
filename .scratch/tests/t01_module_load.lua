-- t01 — module load: require("loci") self-initializes and registers the 8 user
-- commands, with no client spawned before a vault file is opened.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

local cmds = vim.api.nvim_get_commands({})
local lower = {}
for k in pairs(cmds) do
  lower[k:lower()] = true
end
local expected = {
  "LociPalette",
  "LociStatus",
  "LociWorkspaces",
  "LociProjects",
  "LociDoctor",
  "LociDaily",
  "LociScratch",
  "LociNote",
}
for _, n in ipairs(expected) do
  c.expect(lower[n:lower()] ~= nil, "missing user command " .. n)
end
c.expect(
  #vim.lsp.get_clients({ name = "loci" }) == 0,
  "no loci client should exist before a vault file is opened"
)
c.finish()
