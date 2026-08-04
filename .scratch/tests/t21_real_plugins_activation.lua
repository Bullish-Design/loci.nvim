-- t21 — activation editor_state against REAL plugins: haunt.api.change_data_dir
-- (vendored haunt v1.2.0) is actually invoked with the plan's data_dir and
-- succeeds; the resession load runs (vendored v1.2.0); the wayfinder trail load
-- reaches the (stubbed — see README) surface; the writeback still lands on the
-- pinned server.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.setup_resession()
c.capture_notify()

-- REAL haunt, with change_data_dir wrapped to record the dir (the client calls
-- require("haunt.api") at apply time, so the wrapper is what it sees)
vim.opt.rtp:prepend(c.vendor .. "/haunt.nvim")
local haunt_api = require("haunt.api")
local haunt_orig = haunt_api.change_data_dir
local haunt_calls = {}
haunt_api.change_data_dir = function(dir)
  haunt_calls[#haunt_calls + 1] = dir
  return haunt_orig(dir)
end

-- wayfinder: stubbed to the two API functions the client calls (see README)
local wf_loads = {}
package.loaded["wayfinder"] = {
  trail_load_named = function(name)
    wf_loads[#wf_loads + 1] = name
  end,
  trail_active_name = function()
    return nil
  end,
  trail_save_named = function() end,
}

local haunt_dir = c.work .. "/haunt-data"
vim.fn.mkdir(haunt_dir, "p")
local f = io.open(c.work .. "/resp_haunt.json", "w")
f:write(
  '{"editor_state": {"haunt": {"data_dir": "'
    .. haunt_dir
    .. '"}, "resession": {"session_name": "loci-tab-ws", "scope": "tab"}, "wayfinder": {"trail_name": "loci-ws-1-default"}}}'
)
f:close()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_activate.py", c.work .. "/logB", c.work .. "/resp_haunt.json")
vim.wait(1000)
require("resession").save_tab("loci-tab-ws", { attach = false })

loci.activate("ws-1")
vim.wait(3000)

c.expect(
  #haunt_calls == 1 and haunt_calls[1] == haunt_dir,
  "haunt.change_data_dir must be called with the plan's data_dir, got " .. vim.inspect(haunt_calls)
)
c.expect(
  #wf_loads == 1 and wf_loads[1] == "loci-ws-1-default",
  "wayfinder.trail_load_named must receive the plan's trail_name, got " .. vim.inspect(wf_loads)
)
local logB = c.read_file(c.work .. "/logB") or ""
c.expect(logB:find("set_editor_state", 1, true) ~= nil, "writeback must still reach the server: " .. logB)
c.expect(vim.t.loci_workspace_id == "ws-1", "tab marker should be set")
c.finish()
