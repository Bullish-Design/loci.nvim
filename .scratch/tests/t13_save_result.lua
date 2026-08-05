-- t13 — CAS save result (D-041): `didSave` returns `{committed, reason}` and the
-- host reports it back via the `loci/saveResult` notification; a real conflict
-- must surface, an "unchanged" save must stay silent.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local resp = { save = { committed = false, reason = "source_hash_mismatch", revision = nil } }
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

vim.cmd("write") -- triggers textDocument/didSave -> fake sends loci/saveResult
local got = c.wait_for(function()
  return c.any_notice("save not committed")
end, 3000)
c.expect(got, "a CAS conflict must surface a 'save not committed' notice")
local log = c.read_file(c.work .. "/logA") or ""
c.expect(log:find("source_hash_mismatch", 1, true) ~= nil, "saveResult should carry the reason: " .. log)
c.finish()
