-- t07 — new note via `documents/create`: prompt name, engine validates (D-028),
-- created document opens at its real vault-relative path.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_v2.py", c.work .. "/logB")
vim.wait(1000)

vim.ui.input = function(_, cb)
  cb("My Note")
end
loci.new_note()
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_b .. "/notes/x.md", ":p")
end, 4000)
c.expect(opened, "created note should open at the real vault path notes/x.md")
local log = c.read_file(c.work .. "/logB") or ""
c.expect(log:find("req loci/documents/create", 1, true) ~= nil, "documents/create should reach the server: " .. log)
c.expect(log:find("My Note", 1, true) ~= nil, "create should carry the prompted name: " .. log)
c.finish()
