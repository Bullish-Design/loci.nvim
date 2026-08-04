-- t14 — prompt-args (F12): a cancelled REQUIRED arg aborts with a notice and NO
-- command; an empty-`values` vocab never opens a picker (the arg is omitted) and
-- the command fires with the collected args.
-- CASE=A: cancel the required title. CASE=B: give the title, cancel the rest.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_commands.py", c.work .. "/logB")
vim.wait(1000)

local case = vim.env.CASE
local select_calls = 0
local inputs = { "My Note" }
vim.ui.input = function(opts, cb)
  if case == "A" then
    cb(nil) -- cancel the REQUIRED title
  else
    cb(table.remove(inputs, 1) or nil) -- title first, then cancel everything else
  end
end
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  cb(nil)
end

loci.new_note()
vim.wait(2000)
local log = c.read_file(c.work .. "/logB") or ""
if case == "A" then
  c.expect(c.any_notice("required"), "required-arg cancel must notify (F12)")
  c.expect(log:find("loci.note.create", 1, true) == nil, "cancelled required arg must abort BEFORE any command")
else
  c.expect(select_calls == 0, "empty-vocab arg must never open a picker (F12), got " .. select_calls .. " select calls")
  c.expect(log:find("loci.note.create", 1, true) ~= nil, "note.create should fire with the collected args: " .. log)
end
c.finish()
