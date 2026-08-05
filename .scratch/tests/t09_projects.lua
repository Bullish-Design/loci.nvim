-- t09 — projects browser: a project is a managed document whose policy-mapped
-- kind is `project` (arch §11.2 — no separate project entity); open its real path.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

loci.projects()
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/projects/p1.md", ":p")
end, 4000)
c.expect(opened, "project row should open projects/p1.md (the default list has kind=project)")
local log = c.read_file(c.work .. "/logA") or ""
c.expect(log:find("req loci/documents/list", 1, true) ~= nil, "projects should read documents/list: " .. log)
c.finish()
