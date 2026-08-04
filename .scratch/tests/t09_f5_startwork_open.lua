-- t09 — F5 palette start-work: the ActivationPlan's `primary_content_path` is the
-- created note and must be opened AFTER apply_editor_state — i.e. after
-- resession.load churned the LSP attachments (only a client-OBJECT pin survives).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()
c.capture_notify()

local f = io.open(c.work .. "/startwork_resp.json", "w")
f:write('{"primary_content_path": "notes/x.md", "editor_state": {"resession": {"session_name": "loci-tab-ws", "scope": "tab"}}}')
f:close()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
local pinned = vim.api.nvim_get_current_buf()
c.spawn_fake(c.repo_b, c.fakes .. "/fs_commands.py", c.work .. "/logB", c.work .. "/startwork_resp.json")
vim.wait(1000)

-- the workspace's tab-scoped session exists (post-activation state)
require("resession").save_tab("loci-tab-ws", { attach = false })

vim.ui.input = function(opts, cb)
  cb("Quick Note")
end
vim.env.PICK_MATCH = "start-work"
loci.palette()
vim.wait(2500)

local got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
local want = vim.fn.fnamemodify(c.repo_b .. "/.loci/content/notes/x.md", ":p")
c.expect(got == want, "start-work must open the created note (primary_content_path), got " .. got)
c.expect(c.any_notice("started work"), "expected the 'started work' notice")
c.expect(vim.api.nvim_buf_is_valid(pinned), "the pre-flow buffer must survive the resession load")
c.finish()
