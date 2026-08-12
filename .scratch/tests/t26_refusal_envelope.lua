-- t26 — typed server refusals (004 F-13): a feature that answers `{ok: false, error}`
-- must surface the engine's kind+message as an error notice and must NOT invoke the
-- success callback.
--
-- This scenario was previously untestable hermetically: fs_v2 hardcoded `ok: True`
-- and RESPONSE_FILE overrode only `value`, so the entire typed-error surface of the
-- client was covered exactly once (t17, against the real server). fs_v2 now sends an
-- override carrying an "ok" key as the whole envelope.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))

local resp = {
  -- a whole envelope, not a value: this is what the engine sends for a D-028 refusal
  ["loci/documents/create"] = {
    ok = false,
    error = { kind = "InvalidName", message = "name must not contain a path separator" },
  },
  -- a refusal on a READ path too, to prove the envelope check is not create-specific
  ["loci/graph/orphans"] = {
    ok = false,
    error = { kind = "VaultPolicyError", message = "FTS5 is unavailable" },
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

-- a refused effect must notify with kind: message, and must not call back
local called = false
loci.read("documents/create", { name = "a/b" }, function()
  called = true
end)
local refused = c.wait_for(function()
  return c.any_notice("must not contain a path separator")
end, 5000)
c.expect(refused, "a refusal must surface the engine's message: " .. vim.inspect(c.notices))
c.expect(c.any_notice("InvalidName"), "the refusal notice must carry the error kind: " .. vim.inspect(c.notices))
c.expect(not called, "the success callback must NOT run on a refusal")

-- a refused read behaves the same way
local read_called = false
loci.read("graph/orphans", {}, function()
  read_called = true
end)
local read_refused = c.wait_for(function()
  return c.any_notice("FTS5 is unavailable")
end, 5000)
c.expect(read_refused, "a refused read must surface its message: " .. vim.inspect(c.notices))
c.expect(not read_called, "the success callback must NOT run on a refused read")

-- and the client must still be usable afterwards: a refusal is not fatal
local ok_after = false
loci.read("workspaces/list", { include_archived = true }, function()
  ok_after = true
end)
c.expect(c.wait_for(function()
  return ok_after
end, 5000), "a later request must still succeed after a refusal")
c.finish()
