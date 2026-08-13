-- t30 — the save refusal a user actually meets (005 item 1).
--
-- t13 covers `source_hash_mismatch`, which a real neovim CANNOT provoke: nvim writes
-- the file itself and only then sends didSave, so the engine reads disk == buffer and
-- answers `unchanged`. The refusal that DOES fire in daily use is `destination_exists`,
-- on `:w` of a file that did not exist when the buffer opened:
--
--   BufNewFile -> didOpen (file absent) -> the adapter records base_hash = None
--   :w         -> nvim CREATES the file, then sends didSave
--   didSave    -> base is None, so the adapter takes the create branch, and the file
--                 it is about to create already exists -> precondition_failed
--
-- Verified against the real loci-lsp on a 5113-note vault: every `:w` on a new note
-- answered `{committed: false, reason: "destination_exists"}`, and it repeated on every
-- later `:w` in that session because the refusal path never advanced base_hash.
--
-- The engine fix for that is WRITTEN AND TESTED but NOT YET LANDED: it waits in loci-core's
-- `34-live-demo-suite` lane, so the rev this repo's flake.lock pins still refuses. When it
-- lands, `did_save`'s create branch adopts the bytes on disk when they are the bytes the
-- buffer holds, ingests, advances base_hash and answers `unchanged` — which this client is
-- silent about, like every other ordinary `:w`.
--
-- Either way the payload below is the case that SURVIVES that fix — a file that appeared
-- with content the buffer did not write, which the engine refuses now and will keep
-- refusing. What this test pins is the CLIENT's behaviour for a real refusal: name the
-- file, quote the engine's reason verbatim, and say the bytes are on disk without
-- inventing a remedy.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

-- The `revision` here is deliberate: the engine sends one on a COMMITTED save and
-- omits it on a refused one (005, captured from a live loci-lsp). The fake must strip
-- it rather than pass this override through, so a client that read `result.revision`
-- after a conflict cannot find one under test that a real server would never send.
local resp = {
  save = {
    committed = false,
    reason = "destination_exists",
    revision = "36df3e971186d143265440d83e223052b48d2d17843e4696d8f5d66190c84455",
  },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()

-- a file that does NOT exist yet, inside the vault: the BufNewFile path
local newfile = c.repo_a .. "/fresh.md"
vim.cmd("edit " .. vim.fn.fnameescape(newfile))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# fresh", "", "body" })
vim.cmd("write")

local got = c.wait_for(function()
  return c.any_notice("save not committed")
end, 4000)
c.expect(got, "a refused save must surface a notice: " .. vim.inspect(c.notices))
c.expect(c.any_notice("fresh.md"), "the notice must NAME the file: " .. vim.inspect(c.notices))
c.expect(
  c.any_notice("destination_exists"),
  "the notice must quote the engine's reason verbatim: " .. vim.inspect(c.notices)
)
-- "save not committed" reads as YOUR TEXT WAS LOST. It is not: neovim writes before it
-- notifies. The notice must say so.
c.expect(
  c.any_notice("on disk"),
  "the notice must say the bytes are safe: " .. vim.inspect(c.notices)
)
-- ...and it must NOT prescribe a refresh. Measured against the real engine: the LSP host
-- opens at ConsistencyMode.CURRENT and every current read runs a refresh pass, so the file
-- is already visible to search and the graph. 005 shipped ":LociRefresh to re-scan" here on
-- an untested assumption; only an INDEXED read would have needed it, and the host uses none.
c.expect(
  not c.any_notice(":LociRefresh"),
  "the notice must not prescribe a refresh that does nothing: " .. vim.inspect(c.notices)
)

-- The engine omits `revision` when a save is refused; the fake must not pad it (005).
local log = c.read_file(c.work .. "/logA") or ""
local save_line
for line in log:gmatch("[^\n]+") do
  if line:sub(1, 5) == "save " then
    save_line = line
  end
end
c.expect(save_line ~= nil, "the fake should log the saveResult it sent: " .. log)
c.expect(
  save_line and not save_line:find("revision", 1, true),
  "a refused saveResult must carry no `revision` (the engine omits it): " .. tostring(save_line)
)
c.expect(
  save_line and save_line:find("\"uri\"", 1, true) ~= nil,
  "every saveResult carries the uri: " .. tostring(save_line)
)
c.finish()
