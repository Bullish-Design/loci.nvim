-- t29 — a REFUSED effect (engine says ok:true, refusals populated, no document).
--
-- Creating a note whose file already exists is one of the most common actions there
-- is, and the engine handles it by REFUSING rather than erroring: the envelope is
-- `{ok: true, value: {command, changes, refusals: ["...: destination_exists"],
-- _committed: false}}` — with `document` absent/null.
--
-- Two bugs lived here, both invisible to the suite because fs_v2's create always
-- succeeded and always carried a document:
--   1. the refusal was NEVER surfaced — the command looked like it did nothing;
--   2. `open_new_document` guarded `value.document.path` with present() but not
--      `value.document`, and JSON null arrives as vim.NIL — TRUTHY userdata in Lua —
--      so it threw "attempt to index a userdata value" on a real vault.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))

-- The engine's real WIRE refusal shape, captured by probing the live loci-lsp.
--
-- This is deliberately NOT the CLI shape. `loci --json documents/create` projects a
-- CommandPreview (`{refusals: [...], _committed: false}`), but the LSP host sends the
-- SourceCommit itself. A fixture copied from the CLI would validate a client fix that
-- does nothing over the actual wire — which is exactly what happened on the first
-- attempt at this test.
local resp = {
  ["loci/documents/create"] = {
    commit = {
      status = "precondition_failed",
      detail = "destination_exists",
      path = "Existing Note.md",
      old_hash = vim.NIL,
      new_hash = vim.NIL,
    },
    document = vim.NIL, -- explicit JSON null; vim.NIL is TRUTHY userdata in Lua
    revision = "36df3e971186d143265440d83e223052b48d2d17843e4696d8f5d66190c84455",
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

local before = vim.api.nvim_buf_get_name(0)

-- Drive a REAL effect verb (LociNote -> apply_effect -> open_new_document), not
-- loci.read: the refusal reporting and the vim.NIL crash both live on the effect
-- path, so a bare read would exercise neither.
vim.ui.input = function(_, cb)
  cb("Existing Note")
end
local ok = pcall(loci.new_note)
c.expect(ok, "a refused create must not raise")

-- the refusal must be SURFACED, naming the reason and the file
local told = c.wait_for(function()
  return c.any_notice("destination_exists")
end, 8000)
c.expect(told, "a refused effect must tell the user why: " .. vim.inspect(c.notices))
c.expect(c.any_notice("did not commit"), "the notice must read as a refusal: " .. vim.inspect(c.notices))
c.expect(c.any_notice("Existing Note.md"), "the notice must name the file: " .. vim.inspect(c.notices))

-- nothing was created, so the buffer must not have moved
vim.wait(1500)
c.expect(
  vim.api.nvim_buf_get_name(0) == before,
  "a refused create must not open anything (was " .. before .. ", now " .. vim.api.nvim_buf_get_name(0) .. ")"
)
c.finish()
