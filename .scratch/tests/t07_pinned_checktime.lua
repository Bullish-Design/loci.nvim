-- t07 — pinned checktime reload: an effect applied from the doctor hub reloads
-- the PINNED entry buffer (repoB) after the engine's write, even when the current
-- buffer has moved to repoA mid-flow.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

local buf_b
_G.Snacks.picker.pick = function(opts)
  vim.schedule(function()
    -- mid-flow: the engine's write lands on disk, the user switches to repoA
    local f = io.open(c.repo_b .. "/note.md", "w")
    f:write("B after\n")
    f:close()
    vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
    opts.confirm({ close = function() end }, opts.items[1]) -- confirm the fix row
  end)
end

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
buf_b = vim.api.nvim_get_current_buf()
c.spawn_fake(c.repo_b, c.fakes .. "/fs_doctor.py", c.work .. "/logB")
vim.wait(1000)
loci.doctor() -- entry on repoB; fix row -> apply_and_reload pinned to repoB's buffer
vim.wait(1800)
c.expect(
  vim.api.nvim_buf_get_lines(buf_b, 0, 1, false)[1] == "B after",
  "pinned buffer must reload the engine's write, got: " .. vim.api.nvim_buf_get_lines(buf_b, 0, 1, false)[1]
)
c.expect(
  vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p") == vim.fn.fnamemodify(c.repo_a .. "/note.md", ":p"),
  "current buffer stays repoA (only the pinned buffer reloads)"
)
c.finish()
