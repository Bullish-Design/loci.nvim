-- t13 — deactivate wrong-tab guard: when the current tab is attached to a
-- DIFFERENT session (and the active wayfinder trail isn't the workspace's), the
-- deactivate save-plan must NOT clobber the other context's data — but the tab
-- marker still clears.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()

local wf_saves = {}
package.loaded["wayfinder"] = {
  trail_active_name = function()
    return "other-trail" -- NOT the workspace's
  end,
  trail_save_named = function(name)
    wf_saves[#wf_saves + 1] = name
  end,
}

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_status.py", c.work .. "/logB")
vim.wait(1000)

-- the user switched tabs before deactivating: this tab belongs to a different session
require("resession").save_tab("some-other-tab", { attach = true })
local sess_file = c.session_file("loci-ws-1")
os.remove(sess_file)
vim.t.loci_workspace_id = "ws-1"

vim.env.PICK_MATCH = "deactivate"
loci.status()
vim.wait(2000)

c.expect(vim.fn.filereadable(sess_file) == 0, "wrong tab: must NOT re-save the workspace session")
c.expect(#wf_saves == 0, "wrong trail: must NOT save the workspace trail")
c.expect(vim.t.loci_workspace_id == nil, "deactivate must still clear the tab marker")
c.finish()
