-- t11 — global-session guard: a mis-saved GLOBAL `loci-*` session (the <leader>qS
-- danger path) must be loaded with reset=false — the pre-activation buffer
-- survives, a one-time warning fires, and the writeback still reaches the server
-- (client-OBJECT pin through the churn).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()
c.capture_notify()

local f = io.open(c.work .. "/resp_gw.json", "w")
f:write('{"editor_state": {"resession": {"session_name": "loci-gw", "scope": "tab"}}}')
f:close()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
local pinned = vim.api.nvim_get_current_buf()
c.spawn_fake(c.repo_b, c.fakes .. "/fs_activate.py", c.work .. "/logB", c.work .. "/resp_gw.json")
vim.wait(1000)

-- the danger path: the session was saved GLOBAL (resession.save, not save_tab)
require("resession").save("loci-gw", { attach = false })

loci.activate("ws-1")
vim.wait(3000)
c.expect(
  vim.api.nvim_buf_is_valid(pinned),
  "pre-activation buffer must survive the global-session load (reset=false)"
)
c.expect(c.any_notice("global-scoped"), "expected the global-scoped warning")
local logB = c.read_file(c.work .. "/logB") or ""
c.expect(logB:find("set_editor_state", 1, true) ~= nil, "writeback must still reach the server: " .. logB)
c.finish()
