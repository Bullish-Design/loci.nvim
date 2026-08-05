-- t17 — real-server full-stack smoke (V2): the REAL `loci-lsp` binary (this
-- flake's re-export of the engine's pygls host) attaches through the real
-- attach() path, and a full `documents/create` round trip lands on disk:
-- vault bootstrap via `loci init` (the CLI verb), daily note create + open,
-- staleness surfacing from the real envelope, and the engine's D-028 name
-- refusal arriving as a typed envelope error instead of a crash.
--
-- Requires the REAL binaries on PATH: `loci-lsp` and `loci` (the runner's
-- /etc/profiles/per-user/andrew fallback provides the fleet build). The nix
-- check gates it against this flake's own re-export.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

local root = c.repo_b
-- vault bootstrap through the CLI: the client's "not initialized" refusal is a
-- dead end without it, and there is no wire init path (project 002 Q2).
vim.system({ "loci", "init", "--vault", root }, { text = true }, function(obs)
  c.init_rc = obs.code
end)
local inited = c.wait_for(function()
  return c.init_rc ~= nil
end, 15000)
c.expect(inited and c.init_rc == 0, "loci init should succeed (rc=" .. tostring(c.init_rc) .. ")")

-- attach through the REAL attach() autocmd (this test runs WITHOUT the t15
-- shim on PATH, so the real pygls host is what nvim spawns)
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 20000)
c.expect(attached, "the real loci-lsp should attach and initialize within 20s")

-- the full daily flow: the REAL engine creates the note, the client opens it
loci.daily()
local today = os.date("%Y-%m-%d")
local created_file = root .. "/" .. today .. ".md"
local opened = c.wait_for(function()
  return vim.fn.fnamemodify(vim.fn.expand("%:p"), ":p") == vim.fn.fnamemodify(created_file, ":p")
end, 15000)
c.expect(opened, "daily should open the engine-created note at " .. created_file)
local content = c.read_file(created_file)
c.expect(content ~= nil, "the real engine should have written " .. created_file)
if content then
  c.expect(content:find("loci:", 1, true) ~= nil, "the canonical loci region should be in the file: " .. content)
end

-- staleness surfacing (arch §10.2): every real envelope carries the revision
local got_state = c.wait_for(function()
  return vim.t.loci_state and vim.t.loci_state.revision ~= nil
end, 5000)
c.expect(got_state, "vim.t.loci_state should be set from the real envelope")

-- the engine's D-028 refusal arrives as a typed envelope error, not a crash
loci.read("documents/create", { name = "a/b" }, function() end)
local refused = c.wait_for(function()
  return c.any_notice("must not contain")
end, 8000)
c.expect(refused, "an invalid name should surface the engine's refusal as a notice")
c.expect(not c.any_notice("failed"), "no request should fail transport-level: " .. vim.inspect(c.notices))
c.finish()
