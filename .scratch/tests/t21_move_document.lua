-- t21 — `M.move_document`: prompt for a destination -> `documents/move/preview`
-- shows the `move` line (D-032, `MoveDocumentRequest` is `{source, destination}`
-- — 003 decision #3) -> Apply -> `documents/move` sent -> the source buffer
-- reloads (:checktime) and the moved file opens (the committed result carries
-- `.document`, so `open_new_document` reuses it).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

vim.ui.input = function(_, cb)
  cb("notes/b.md")
end
local preview_prompt
local checktimes = 0
local orig_checktime = vim.cmd.checktime
vim.cmd.checktime = function(arg)
  checktimes = checktimes + 1
  return orig_checktime(arg)
end
vim.ui.select = function(items, opts, cb)
  preview_prompt = opts and opts.prompt
  cb(items[1]) -- "Apply"
end
loci.move_document()
local moved = c.wait_for(function()
  local l = c.read_file(c.work .. "/logA") or ""
  return l:find("req loci/documents/move/preview", 1, true) ~= nil
    and l:find("req loci/documents/move", 1, true) ~= nil
    and l:find("notes/b.md", 1, true) ~= nil
end, 8000)
c.expect(moved, "move should preview then apply documents/move with the destination")
c.expect(
  preview_prompt ~= nil and preview_prompt:find("move note.md", 1, true) ~= nil,
  "the preview prompt should render the engine's move line: " .. tostring(preview_prompt)
)
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/notes/b.md", ":p")
end, 4000)
c.expect(opened, "after apply the moved file (notes/b.md) should open")
c.expect(checktimes >= 1, "apply_effect should have run :checktime on the source buffer")
c.expect(not c.any_notice("failed"), "a clean move must not surface errors")
c.finish()
