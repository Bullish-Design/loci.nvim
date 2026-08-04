-- t04 — single-vault regression: the projects hub row opens the note in the one
-- vault present.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_index.py")
vim.wait(1000)
loci.projects()
vim.wait(1500)
local got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
local want = vim.fn.fnamemodify(c.repo_a .. "/.loci/content/projects/p1.md", ":p")
c.expect(got == want, "single vault: project row should open the vault's note, got " .. got)
c.finish()
