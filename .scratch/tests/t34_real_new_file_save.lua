-- t34 — the new-note `:w`, against the REAL engine (005 F-01, closed).
--
-- t30 pins the CLIENT's behaviour for a save the engine really refuses. Nothing
-- pinned the case a user meets far more often: `:w` on a note that did not exist
-- when the buffer opened. That path was a live bug for the whole of project 005 —
--
--   BufNewFile -> didOpen (file absent) -> the adapter records base_hash = None
--   :w         -> nvim CREATES the file, then sends didSave
--   didSave    -> base is None, so the adapter takes the create branch, and the
--                 file it is about to create already exists
--
-- — and it answered `{committed: false, reason: "destination_exists"}` on EVERY
-- save for the life of the session, because the refusal returned before it could
-- advance base_hash. Worse than the warning: `ingest_source` never ran, so the
-- save did no indexing work at all.
--
-- loci-core c34dc83 (v0.4.1) fixes it: the create branch adopts the bytes on disk
-- when they are the bytes the buffer holds, ingests, advances base_hash, and
-- answers `unchanged` — which this client is silent about, like every other
-- ordinary `:w`.
--
-- WHY THE REAL BINARY. A fake cannot prove this. The bug lived in the ORDER the
-- host sees events (nvim writes first, then notifies), and the engine's own suite
-- missed it for exactly that reason: every create-branch test there let the server
-- write the file, which is the one order neovim never uses. Only the real adapter,
-- driven by a real `:w`, measures it.
--
-- Requires `loci-lsp` and `loci` on PATH, like t17; the nix check supplies this
-- flake's own re-export.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

local root = c.repo_b
vim.system({ "loci", "init", "--vault", root }, { text = true }, function(obs)
  c.init_rc = obs.code
end)
local inited = c.wait_for(function()
  return c.init_rc ~= nil
end, 15000)
c.expect(inited and c.init_rc == 0, "loci init should succeed (rc=" .. tostring(c.init_rc) .. ")")

-- Record every `loci/saveResult` the host sends, then hand it to the client's own
-- handler. The client is SILENT on the good path, so "no notice" alone would also
-- pass if the save never happened at all. The recorded payload is the ground truth.
local saves = {}
local client_handler = vim.lsp.handlers["loci/saveResult"]
vim.lsp.handlers["loci/saveResult"] = function(err, result, ctx, config)
  saves[#saves + 1] = result
  return client_handler(err, result, ctx, config)
end

-- attach through the REAL attach() autocmd on a file that exists
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 20000)
c.expect(attached, "the real loci-lsp should attach and initialize within 20s")

-- The BufNewFile path: a file that does NOT exist yet, inside the vault.
local newfile = root .. "/fresh.md"
c.expect(vim.fn.filereadable(newfile) == 0, "the premise: " .. newfile .. " must not exist yet")
vim.cmd("edit " .. vim.fn.fnameescape(newfile))
local buf = vim.api.nvim_get_current_buf()
-- didOpen must reach the server BEFORE nvim writes the file, or base_hash is the
-- disk hash, the create branch never runs, and this test passes for the wrong
-- reason. Wait for the attach, then let the notification drain.
local buf_attached = c.wait_for(function()
  return vim.b[buf].loci_attached == true
end, 20000)
c.expect(buf_attached, "the new-file buffer must attach before the write")
vim.wait(500)

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# fresh", "", "body" })
vim.cmd("write")

local first = c.wait_for(function()
  return #saves >= 1
end, 15000)
c.expect(first, "the host must answer the first `:w` with a loci/saveResult")
if saves[1] then
  c.expect(
    saves[1].reason == "unchanged",
    "a new note's first `:w` must answer `unchanged`, not a refusal: " .. vim.inspect(saves[1])
  )
  c.expect(
    saves[1].reason ~= "destination_exists",
    "F-01 regression: the create branch refused an ordinary new-note save"
  )
end
c.expect(vim.fn.filereadable(newfile) == 1, "nvim should have written " .. newfile)
c.expect(
  not c.any_notice("save not committed"),
  "an ordinary new-note `:w` must be silent: " .. vim.inspect(c.notices)
)

-- The second half of F-01: the refusal never advanced base_hash, so it repeated on
-- every later `:w` in the session. Save again and hold the same bar.
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "more" })
vim.cmd("write")
local second = c.wait_for(function()
  return #saves >= 2
end, 15000)
c.expect(second, "the host must answer the second `:w` too")
if saves[2] then
  c.expect(
    saves[2].reason == "unchanged",
    "a later `:w` on the same note must also answer `unchanged`: " .. vim.inspect(saves[2])
  )
end
c.expect(
  not c.any_notice("save not committed"),
  "no save in this session may warn: " .. vim.inspect(c.notices)
)

c.finish()
