-- t20 — real full-stack smoke with the REAL loci-lsp: initialize a vault via the
-- engine's own `loci.repository.init`, then `M.daily()` — the real engine writes
-- the daily note and the client opens it (the F5 open path against the real
-- wire, not a fake).
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

-- the runner puts a `loci-lsp` shim (fake server) first on PATH for t16; this
-- test wants the REAL binary
vim.env.PATH = vim.env.PATH:gsub("^" .. vim.pesc(c.work .. "/bin:") , "")

-- an EMPTY `.loci/` marker is what the attach autocmd looks for; the engine
-- initializes the repository through the wire below
vim.fn.mkdir(c.repo_b .. "/.loci", "p")
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_b .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 12000)
c.expect(attached, "real loci-lsp should attach within 12s")
if not attached then
  c.finish()
  return
end

-- seed the repository through the wire (the engine owns all vault state)
local reached = false
loci.command("loci.repository.init", {}, function(value)
  reached = true
end)
local seeded = c.wait_for(function()
  return reached == true
end, 8000)
c.expect(seeded, "repository.init should reach the real engine")
vim.wait(500)

-- now the full daily flow: real engine creates the note, client opens it
loci.daily()
local opened = c.wait_for(function()
  local name = vim.fn.expand("%:p")
  return name:find(".loci/content/daily/", 1, true) ~= nil
end, 8000)
c.expect(opened, "the real engine's daily note should be opened, got " .. vim.fn.expand("%:p"))
if opened then
  -- the engine really wrote it (sole-writer): the file exists with a frontmatter
  local path = vim.fn.expand("%:p")
  local content = c.read_file(path) or ""
  c.expect(content:find("---", 1, true) ~= nil, "the created note should have real engine frontmatter")
  c.expect(content ~= "", "the created note should be non-empty")
end
c.finish()
