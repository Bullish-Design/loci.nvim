-- t18 — F6 git observation: the writeback resolves the worktree EXPLICITLY —
-- the recorded `worktree_path`, else the vault root — never the tab dir.
-- CASE=first: no recorded worktree (engine sent null) and the launch dir is NOT a
-- repo -> the writeback must record the VAULT ROOT's branch.
-- CASE=recorded: a recorded worktree (repoA, branch feature-x) wins over the tab
-- dir -> the writeback must record repoA + feature-x.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
local case = vim.env.CASE

-- the activation-plan response is case-specific (paths are sandbox-specific)
local resp = io.open(c.work .. "/resp.json", "w")
if case == "first" then
  resp:write('{"editor_state": {"git": {"branch": null, "worktree_path": null}}}')
else
  resp:write('{"editor_state": {"git": {"branch": null, "worktree_path": "' .. c.repo_a .. '"}}}')
end
resp:close()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_activate.py", c.work .. "/logB", c.work .. "/resp.json")
vim.wait(1000)
loci.activate("ws-1")
vim.wait(3000)

local log = c.read_file(c.work .. "/logB") or ""
c.expect(log:find("set_editor_state", 1, true) ~= nil, "git writeback should reach the server, got: " .. log)
if case == "first" then
  c.expect(
    log:find(c.repo_b, 1, true) ~= nil,
    "first activation: writeback must use the VAULT ROOT, got: " .. log
  )
  c.expect(log:find('"branch": "main-b"', 1, true) ~= nil, "first activation: must record the vault's branch, got: " .. log)
else
  c.expect(
    log:find(c.repo_a, 1, true) ~= nil,
    "recorded worktree must WIN over the tab dir, got: " .. log
  )
  c.expect(
    log:find('"branch": "feature-x"', 1, true) ~= nil,
    "recorded worktree must record ITS branch, got: " .. log
  )
end
c.finish()
