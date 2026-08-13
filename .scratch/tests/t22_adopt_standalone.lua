-- t22 — standalone adoption verb: `M.adopt` previews `documents/adopt` (its
-- declared pure route, D-032), applies it with `{path}` = the current buffer's
-- vault-relative path (AdoptRequest is `{path, proposed_id?}` — 003 decision #5),
-- and reloads the buffer (:checktime) as the engine wrote it.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

local checktimes = 0
local orig_checktime = vim.cmd.checktime
vim.cmd.checktime = function(arg)
  checktimes = checktimes + 1
  return orig_checktime(arg)
end
vim.ui.select = function(items, _, cb)
  cb(items[1]) -- "Apply"
end
loci.adopt()
local adopted = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/documents/adopt/preview", 1, true) ~= nil
    and l:find("req loci/documents/adopt", 1, true) ~= nil
    and l:find('"path": "note.md"', 1, true) ~= nil
end, 8000)
c.expect(adopted, "adopt should preview then apply documents/adopt with {path} = the buffer rel path")
-- `adopted` polls the SERVER's log, so it goes true when the fake RECEIVES the apply —
-- before the client has read the response and run its `vim.schedule`d reload. Asserting
-- the reload right here raced that schedule and failed under load (seen once in the nix
-- check, never locally). t21 asserts the same thing safely because it first waits for the
-- moved file to open, which happens AFTER the checktime. Wait for the effect itself.
local reloaded = c.wait_for(function()
  return checktimes >= 1
end, 4000)
c.expect(reloaded, "apply_effect should have run :checktime to reload the engine-written buffer")
c.expect(not c.any_notice("failed"), "a clean adopt must not surface errors")
c.finish()
