-- t08 — daily note is a client-side `documents/create` template (§11.2): the
-- name is today's date, the created document opens.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
local today = os.date("%Y-%m-%d")
-- make the fake return the real date path so the open is meaningful
local resp = {
  ["loci/documents/create"] = {
    document = { path = "notes/" .. today .. ".md", id = "id-d", kind = "daily",
                 title = today, status = nil, state = "managed", identity_state = "ok" },
    commit = { status = "committed" }, revision = "r1",
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

loci.daily()
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/notes/" .. today .. ".md", ":p")
end, 4000)
c.expect(opened, "daily note should open at notes/" .. today .. ".md")
local log = c.read_file(c.work .. "/logA") or ""
c.expect(log:find("req loci/documents/create", 1, true) ~= nil, "daily should use documents/create: " .. log)
c.expect(log:find(today, 1, true) ~= nil, "create should carry today's name: " .. log)
c.finish()
