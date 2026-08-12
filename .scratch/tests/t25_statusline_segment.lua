-- t25 — statusline staleness segment: `vim.t.loci_state` is populated from every
-- feature response, so `M.statusline()` returns the ABBREVIATED revision when the
-- read was `current` and `<rev>!` when `_consistency` is `indexed` (arch §10.2).
-- The `indexed` case comes from a FS_RESPONSE override on `loci/maintenance/refresh`.
--
-- The revision the engine sends is a full 64-char content hash. This test used to
-- assert against a 2-char fake ("r1"), which is why a segment that emitted the raw
-- revision — unusable on a real vault — passed CI. fs_v2 now returns a real-width
-- hash and the width assertion below is the actual regression guard.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))

-- the same full-width revision fs_v2 appends to every envelope
local REV = "36df3e971186d143265440d83e223052b48d2d17843e4696d8f5d66190c84455"
local SHORT = REV:sub(1, 7) -- "36df3e9"

local resp = {
  ["loci/maintenance/refresh"] = {
    _revision = REV, _consistency = "indexed", changed_sources = 0, diagnostics_summary = {},
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

c.expect(loci.statusline() == "", "before any feature response the segment must be empty")

-- a default (current) read -> the abbreviated revision, NOT the full hash
loci.read("workspaces/list", { include_archived = true }, function() end)
local current = c.wait_for(function()
  return loci.statusline() == SHORT
end, 4000)
c.expect(current, "a current read must yield the segment '" .. SHORT .. "' (got '" .. loci.statusline() .. "')")

-- the width guard: the segment must stay statusline-sized regardless of how long
-- the engine's revision is. This is the assertion the old 'r1' fake could not make.
local seg_current = loci.statusline()
c.expect(
  #seg_current <= 8,
  "the segment must be abbreviated, not the raw 64-char revision (got " .. #seg_current .. " chars: '" .. seg_current .. "')"
)
c.expect(
  not seg_current:find(REV, 1, true),
  "the segment must never contain the full revision hash (got '" .. seg_current .. "')"
)

-- the overridden indexed read -> <short>!
loci.refresh()
local stale = c.wait_for(function()
  return loci.statusline() == SHORT .. "!"
end, 4000)
c.expect(stale, "an indexed (stale) read must yield '" .. SHORT .. "!' (got '" .. loci.statusline() .. "')")
c.expect(#loci.statusline() <= 9, "the stale segment must also stay abbreviated (got '" .. loci.statusline() .. "')")
c.finish()
