-- t24 — unmanaged escape hatch (Q3): the default filter drops `unmanaged` rows
-- (t12 behavior must keep holding), `:LociToggleUnmanaged` flips the
-- `vim.g.loci_show_unmanaged` flag, and with it set the SAME pushed diagnostics
-- pass through unfiltered.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
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
-- open the buffer FIRST, then spawn: nvim sends didOpen for already-open
-- buffers when the client initializes (t12's exact pattern)
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", "", c.work .. "/diags.json")
vim.wait(1000)

local function codes(bufnr)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    out[#out + 1] = d.code
  end
  return out
end

local bufnr = vim.api.nvim_get_current_buf()
local got = c.wait_for(function()
  return #vim.diagnostic.get(bufnr) > 0
end, 4000)
c.expect(got, "server should push diagnostics after didOpen")
c.expect(
  not vim.tbl_contains(codes(bufnr), "unmanaged"),
  "default filter must drop unmanaged (got: " .. vim.inspect(codes(bufnr)) .. ")"
)
c.expect(vim.tbl_contains(codes(bufnr), "missing_target"), "missing_target must still pass the default filter")

-- flip the flag, then PULL diagnostics (the production path: nvim pulls
-- because the host advertises diagnosticProvider) — the same wrapped handler
-- now lets `unmanaged` through
vim.cmd("LociToggleUnmanaged")
c.expect(vim.g.loci_show_unmanaged == true, "the toggle should set vim.g.loci_show_unmanaged")
c.expect(c.any_notice("unmanaged diagnostics shown"), "the toggle should announce the new mode")
local client = vim.lsp.get_clients({ name = "loci" })[1]
client:request("textDocument/diagnostic",
  { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, nil, bufnr)
local shown = c.wait_for(function()
  return vim.tbl_contains(codes(bufnr), "unmanaged")
end, 4000)
c.expect(shown, "with loci_show_unmanaged set, unmanaged rows must pass through (got: " .. vim.inspect(codes(bufnr)) .. ")")
c.finish()
