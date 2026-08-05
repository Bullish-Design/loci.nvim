-- t12 — diagnostic severity filter: V2 emits `unmanaged` at information for
-- every unmanaged document (D-047; arch §13 says hosts may filter it). The
-- client must drop `unmanaged` and keep actionable families (`missing_target`).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local diags = {
  {
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
    severity = 3, code = "unmanaged", message = "unmanaged", source = "loci",
  },
  {
    range = { start = { line = 2, character = 1 }, ["end"] = { line = 2, character = 12 } },
    severity = 2, code = "missing_target", message = "missing_target", source = "loci",
  },
}
local f = io.open(c.work .. "/diags.json", "w")
f:write(vim.json.encode(diags))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", "", c.work .. "/diags.json")
vim.wait(1000)

local bufnr = vim.api.nvim_get_current_buf()
local got = c.wait_for(function()
  return #vim.diagnostic.get(bufnr) > 0
end, 4000)
c.expect(got, "server should push diagnostics after didOpen")
local codes = {}
for _, d in ipairs(vim.diagnostic.get(bufnr)) do
  codes[#codes + 1] = d.code
end
c.expect(not vim.tbl_contains(codes, "unmanaged"), "unmanaged must be filtered out (got: " .. vim.inspect(codes) .. ")")
c.expect(vim.tbl_contains(codes, "missing_target"), "missing_target must be kept (got: " .. vim.inspect(codes) .. ")")
c.finish()
