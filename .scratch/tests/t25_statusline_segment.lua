-- t25 — statusline staleness segment: `vim.t.loci_state` is populated from every
-- feature response, so `M.statusline()` returns `r1` when the read was `current`
-- and `r1!` when `_consistency` is `indexed` (arch §10.2). The `indexed` case
-- comes from a FS_RESPONSE override on `loci/maintenance/refresh`.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local resp = {
  ["loci/maintenance/refresh"] = {
    _revision = "r1", _consistency = "indexed", changed_sources = 0, diagnostics_summary = {},
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

c.expect(loci.statusline() == "", "before any feature response the segment must be empty")

-- a default (current) read -> r1
loci.read("workspaces/list", { include_archived = true }, function() end)
local current = c.wait_for(function()
  return loci.statusline() == "r1"
end, 4000)
c.expect(current, "a current read must yield the segment 'r1' (got '" .. loci.statusline() .. "')")

-- the overridden indexed read -> r1!
loci.refresh()
local stale = c.wait_for(function()
  return loci.statusline() == "r1!"
end, 4000)
c.expect(stale, "an indexed (stale) read must yield the segment 'r1!' (got '" .. loci.statusline() .. "')")
c.finish()
