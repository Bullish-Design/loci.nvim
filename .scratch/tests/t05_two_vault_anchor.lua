-- t05 — F1 root anchoring: with TWO vaults open (repoA attached first), the
-- projects hub on repoB's buffer must open the note in repoB — never the
-- first-attached client's root.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_index.py")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_index.py")
vim.wait(1200)

-- current buffer = repoB; first client by name is repoA
loci.projects()
vim.wait(1500)
local got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
c.expect(
  got == vim.fn.fnamemodify(c.repo_b .. "/.loci/content/projects/p1.md", ":p"),
  "two-vault: on repoB the row must open repoB's note, got " .. got
)

-- switch to repoA and repeat: now the open must land in repoA
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
loci.projects()
vim.wait(1500)
got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
c.expect(
  got == vim.fn.fnamemodify(c.repo_a .. "/.loci/content/projects/p1.md", ":p"),
  "two-vault: on repoA the row must open repoA's note, got " .. got
)
c.finish()
