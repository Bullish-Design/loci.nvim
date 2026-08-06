-- t18 — link-a-file-to-workspace: `M.link_file` reads the pinned workspace's
-- view (`workspaces/get`), appends the current buffer's file with a role, PUTs
-- the full list (the engine's manifest is wholly-owned: PUT REPLACES, so this
-- is read-modify-write — 003 decision #1), preview-first (D-032). Also pins the
-- "no workspace pinned" gate.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

-- gate: no pinned workspace -> informational refusal, no request sent
loci.link_file()
local gated = c.wait_for(function()
  return c.any_notice("no workspace pinned")
end, 2000)
c.expect(gated, "link_file without a pin should refuse with 'no workspace pinned'")

-- happy path: pin, pick the implementation role, Apply the preview
vim.t.loci_workspace_id = "ws-1"
vim.env.PICK_MATCH = "implementation"
vim.ui.select = function(items, _, cb)
  cb(items[1]) -- "Apply"
end
loci.link_file()
local linked = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/workspaces/get", 1, true) ~= nil
    and l:find("req loci/workspaces/put/preview", 1, true) ~= nil
    and l:find("req loci/workspaces/put", 1, true) ~= nil
    and l:find("note.md", 1, true) ~= nil
    and l:find("implementation", 1, true) ~= nil
end, 8000)
c.expect(linked, "link_file should get the view then preview+put workspaces/put with {path, role}")
local log = c.read_file(c.work .. "/logA") or ""
c.expect(log:find('"files"', 1, true) ~= nil, "the put should carry the files list: " .. log)
c.expect(log:find('"documents"', 1, true) ~= nil, "the put must round-trip the view's documents (PUT replaces the manifest): " .. log)
c.expect(not c.any_notice("failed"), "a clean link must not surface errors")
c.finish()
