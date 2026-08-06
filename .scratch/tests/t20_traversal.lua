-- t20 — `M.traversal`: sends `loci/graph/traversal` with `{ref}` (depth defaults
-- to 3 engine-side); rows carry `[path, depth]` and the picker renders the depth
-- suffix `(depth n)`; selecting a row opens its path.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

-- capture the picker rows, then confirm the notes/b.md row
local captured
local orig_pick = _G.Snacks.picker.pick
_G.Snacks.picker.pick = function(opts)
  captured = opts.items
  for _, it in ipairs(opts.items) do
    if it.text:find("notes/b.md", 1, true) then
      opts.confirm({ close = function() end }, it)
      return
    end
  end
  orig_pick(opts)
end
loci.traversal()
local asked = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/graph/traversal", 1, true) ~= nil
    and l:find('"ref": "note.md"', 1, true) ~= nil
end, 4000)
c.expect(asked, "traversal should send loci/graph/traversal with {ref} = the buffer's rel path")
c.expect(captured ~= nil and #captured > 0, "the traversal rows should be picked")
if captured then
  local depth_shown = false
  for _, it in ipairs(captured) do
    if it.path == "notes/b.md" and it.text:find("(depth 1)", 1, true) then
      depth_shown = true
    end
  end
  c.expect(depth_shown, "a depth-1 row must render as 'path  (depth 1)'")
end
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/notes/b.md", ":p")
end, 4000)
c.expect(opened, "a traversal row should open its real vault path (notes/b.md)")
c.finish()
