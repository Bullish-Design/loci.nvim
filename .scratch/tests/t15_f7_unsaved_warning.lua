-- t15 — F7 unsaved-buffer clobber warning: when the effect's target buffer still
-- has unsaved changes after the engine wrote the file, :checktime refuses and the
-- client warns that a later :w would overwrite the engine's edit.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
c.spawn_fake(c.repo_b, c.fakes .. "/fs_doctor.py", c.work .. "/logB")
vim.wait(1000)
local b = vim.api.nvim_get_current_buf()
vim.bo[b].modified = true -- unsaved changes
local orig = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]

_G.Snacks.picker.pick = function(opts)
  -- the engine's write lands on disk before the fix row is confirmed
  local f = io.open(c.repo_b .. "/note.md", "w")
  f:write("ENGINE WROTE NEW CONTENT\n")
  f:close()
  opts.confirm({ close = function() end }, opts.items[1])
end
loci.doctor()
vim.wait(2000)

c.expect(c.any_notice("unsaved changes"), "F7: expected the unsaved-changes clobber warning")
c.expect(
  vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == orig,
  "the buffer must keep its unsaved content (:checktime refuses to clobber)"
)
c.finish()
