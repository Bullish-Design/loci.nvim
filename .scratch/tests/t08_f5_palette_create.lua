-- t08 — F5 palette note.create: creating a note from the palette must OPEN the
-- created note (exactly like :LociNote), not silently create it.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_commands.py", c.work .. "/logB")
vim.wait(1000)

-- answer the required title prompt; cancel the optional rest
local inputs = { "My Note" }
vim.ui.input = function(opts, cb)
  cb(table.remove(inputs, 1) or nil)
end
vim.env.PICK_MATCH = "note.create"
loci.palette()
vim.wait(2000)

local got = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
local want = vim.fn.fnamemodify(c.repo_b .. "/.loci/content/notes/x.md", ":p")
c.expect(got == want, "palette note.create must open the created note, got " .. got)
local log = c.read_file(c.work .. "/logB") or ""
c.expect(log:find("loci.note.create", 1, true) ~= nil, "note.create should reach the server: " .. log)
c.finish()
