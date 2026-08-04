-- t06 — F3 mid-flow vault switch: a flow that starts on repoB must finish its
-- open in repoB even if the user switches to a repoA buffer while the picker is
-- up.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

local switched = false
_G.Snacks.picker.pick = function(opts)
  vim.schedule(function()
    vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md")) -- vault switch AFTER the flow started
    switched = true
    opts.confirm({ close = function() end }, opts.items[1])
  end)
end

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_index.py")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_index.py")
vim.wait(1200)

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
loci.projects() -- flow entry: repoB
vim.wait(1800)
local got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
c.expect(switched, "picker stub should have switched buffers mid-flow")
c.expect(
  got == vim.fn.fnamemodify(c.repo_b .. "/.loci/content/projects/p1.md", ":p"),
  "mid-flow switch: open must stay in the entry vault repoB, got " .. got
)
c.finish()
