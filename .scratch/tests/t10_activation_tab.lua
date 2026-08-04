-- t10 — activation routing to the RIGHT vault through a tab-scoped resession
-- load: the writeback must reach repoB's server (the entry client), never repoA's,
-- even though resession.load detaches every buffer from its client mid-flow.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()

local f = io.open(c.work .. "/resp_tab.json", "w")
f:write('{"editor_state": {"resession": {"session_name": "loci-tab-ws", "scope": "tab"}}, "workspace_id": "ws-1"}')
f:close()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_activate.py", c.work .. "/logA", c.work .. "/resp_tab.json")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_activate.py", c.work .. "/logB", c.work .. "/resp_tab.json")
vim.wait(1200)

-- the workspace's session exists (tab-scoped, the designed path)
require("resession").save_tab("loci-tab-ws", { attach = false })

loci.activate("ws-1") -- entry: current buffer = repoB
vim.wait(3000)
local logA = c.read_file(c.work .. "/logA") or ""
local logB = c.read_file(c.work .. "/logB") or ""
c.expect(logB:find("set_editor_state", 1, true) ~= nil, "writeback must reach repoB's server, got: " .. logB)
c.expect(logA:find("set_editor_state", 1, true) == nil, "writeback must NOT reach repoA's server")
c.expect(logA:find("loci.workspace.activate", 1, true) == nil, "repoA's server must see nothing at all")
c.expect(vim.t.loci_workspace_id == "ws-1", "tab marker should be set")
c.finish()
