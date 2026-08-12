-- t06 — status hub renders the pinned WorkspaceView: documents and files rows
-- open files at their REAL vault-relative paths (no `.loci/content/` jail).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
-- custom workspaces/get with a project, one document and one linked file
local resp = {
  ["loci/workspaces/get"] = {
    view = {
      id = "ws-1", name = "WS1", path = ".loci/workspaces/ws1.yaml",
      project = "projects/p1.md", archived = false,
      -- real-shaped resource id (a UUID, not "id-a") per 004 R6
      documents = { { "notes/a.md", "primary", "7527c974-673b-44f6-81ee-7a2214a96604", "Resolved", "notes/a.md" } },
      files = { { "src/x.py", "implementation" } },
    },
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

vim.t.loci_workspace_id = "ws-1"
-- PICK_INDEX=3 -> the note row (rows: header, project, note, file, …)
vim.env.PICK_INDEX = "3"
loci.status()
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p")
    == vim.fn.fnamemodify(c.repo_a .. "/notes/a.md", ":p")
end, 4000)
c.expect(opened, "status hub note row should open the real vault path notes/a.md")
c.finish()
