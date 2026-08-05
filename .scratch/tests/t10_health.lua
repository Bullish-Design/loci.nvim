-- t10 — vault-health hub (replaces the deleted doctor, arch §18): refresh +
-- the graph queries that are the V2-native findings; a finding row opens the
-- source at its real path.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_v2.py", c.work .. "/logB")
vim.wait(1000)

-- PICK_MATCH -> the broken-links group row -> its sub-picker -> open notes/a.md
vim.env.PICK_MATCH = "broken links"
loci.doctor()
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_b .. "/notes/a.md", ":p")
end, 5000)
c.expect(opened, "broken-links finding should open its source path")

local log = c.read_file(c.work .. "/logB") or ""
for _, m in ipairs({
  "req loci/maintenance/refresh",
  "req loci/graph/broken_links",
  "req loci/graph/missing_attachments",
  "req loci/graph/ambiguous_links",
  "req loci/graph/orphans",
}) do
  c.expect(log:find(m, 1, true) ~= nil, "health hub should send " .. m .. ": " .. log)
end
c.finish()
