-- t19 — `M.neighbors`: sends `loci/graph/neighbors` with the current buffer's
-- vault-relative `ref`; rows are FLAT paths (the engine projects `GraphResult.rows`
-- for neighbors as a plain path list — 003 decision #2); a row opens its path.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

loci.neighbors()
local asked = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/graph/neighbors", 1, true) ~= nil
    and l:find('"ref": "note.md"', 1, true) ~= nil
end, 4000)
c.expect(asked, "neighbors should send loci/graph/neighbors with {ref} = the buffer's rel path")
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/notes/b.md", ":p")
end, 4000)
c.expect(opened, "a neighbor row should open its real vault path (notes/b.md)")
c.expect(not c.any_notice("failed"), "a clean neighbors read must not surface errors")
c.finish()
