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

-- The COMMAND ALONE must make the change visible.
--
-- This test used to issue its own `textDocument/diagnostic` request here, which
-- proved the filter honours the flag but never that the command refreshes
-- anything — and the command did NOT: it flipped `vim.g.loci_show_unmanaged`,
-- announced the new mode, and left the screen untouched until the buffer next
-- changed. Verified against a real vault (1 row before the toggle, 1 after).
-- No manual re-pull below: `toggle_unmanaged` owns that now.
vim.cmd("LociToggleUnmanaged")
c.expect(vim.g.loci_show_unmanaged == true, "the toggle should set vim.g.loci_show_unmanaged")
c.expect(c.any_notice("unmanaged diagnostics shown"), "the toggle should announce the new mode")
local shown = c.wait_for(function()
  return vim.tbl_contains(codes(bufnr), "unmanaged")
end, 6000)
c.expect(shown, "the toggle ALONE must reveal unmanaged rows (got: " .. vim.inspect(codes(bufnr)) .. ")")
c.expect(c.any_notice("refreshed"), "the toggle should report the buffers it refreshed")

-- and toggling back must hide them again, also without help
vim.cmd("LociToggleUnmanaged")
local hidden = c.wait_for(function()
  return not vim.tbl_contains(codes(bufnr), "unmanaged")
end, 6000)
c.expect(hidden, "toggling back must re-filter (got: " .. vim.inspect(codes(bufnr)) .. ")")
c.expect(vim.tbl_contains(codes(bufnr), "missing_target"), "real diagnostics must survive both toggles")
c.finish()
