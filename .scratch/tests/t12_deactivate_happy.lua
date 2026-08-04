-- t12 — deactivate happy path (F2/F4/F8): the status-hub deactivate row runs the
-- effect with NO args (the op clears the Current pointer), applies the engine's
-- DeactivationPlan — saving the workspace's resession session + wayfinder trail —
-- and clears the tab marker.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()

-- faithful stub of the two wayfinder functions the client calls (the real plugin's
-- trail backend needs its interactive stack; see tests/README.md)
local wf_saves = {}
package.loaded["wayfinder"] = {
  trail_active_name = function()
    return "loci-ws-1-default"
  end,
  trail_save_named = function(name)
    wf_saves[#wf_saves + 1] = name
  end,
}

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_status.py", c.work .. "/logB")
vim.wait(1000)

-- post-activation state: THIS tab is attached to the workspace's session
require("resession").save_tab("loci-ws-1", { attach = true })
local sess_file = c.session_file("loci-ws-1")
os.remove(sess_file) -- a re-save is detectable
vim.t.loci_workspace_id = "ws-1"

vim.env.PICK_MATCH = "deactivate"
loci.status()
vim.wait(2000)

c.expect(vim.fn.filereadable(sess_file) == 1, "deactivate must re-save the workspace session (plan.save_session)")
c.expect(
  #wf_saves == 1 and wf_saves[1] == "loci-ws-1-default",
  "deactivate must save the workspace trail (plan.save_wayfinder), got " .. vim.inspect(wf_saves)
)
c.expect(vim.t.loci_workspace_id == nil, "deactivate must clear the tab marker (F8)")
c.finish()
