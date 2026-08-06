-- t23 — registry-mirrored palette (Q5, 003 decision #6): `M.palette` renders the
-- new verbs (adopt/move/link/neighbors/traversal/toggle unmanaged) alongside the
-- bespoke ones; selecting "Neighbors" issues the `loci/graph/neighbors` request.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

local captured
local orig_pick = _G.Snacks.picker.pick
_G.Snacks.picker.pick = function(opts)
  captured = opts.items
  for _, it in ipairs(opts.items) do
    if it.text == "Neighbors" then
      opts.confirm({ close = function() end }, it)
      return
    end
  end
  orig_pick(opts)
end
loci.palette()
c.expect(captured ~= nil and #captured >= 14, "the palette should render the curated registry rows")
if captured then
  local texts = {}
  for _, it in ipairs(captured) do
    texts[#texts + 1] = it.text
  end
  for _, want in ipairs({
    "Adopt current note", "Move current note", "Link current file to workspace",
    "Neighbors", "Traversal", "Project members", "Toggle unmanaged diagnostics",
  }) do
    c.expect(vim.tbl_contains(texts, want), "palette must include '" .. want .. "'")
  end
end
local neighbors = c.wait_for(function()
  return (c.read_file(c.work .. "/logA") or ""):find("req loci/graph/neighbors", 1, true) ~= nil
end, 4000)
c.expect(neighbors, "selecting Neighbors should issue the graph/neighbors request")
c.finish()
