-- t32 — the interactive gap (005 item 3): render a real UI and press real keys.
--
-- Every other test in this suite calls the client and stubs the prompt. That proves
-- the callback runs and nothing about whether the prompt DRAWS or whether answering
-- it works — and `vim.ui.select` is exactly where that mattered: headless it blocks
-- forever, so the confirm step of every preview-then-apply flow, and every picker on
-- a machine without Snacks, had never once been answered by a keypress.
--
-- Here a child nvim runs its ordinary TUI inside a terminal buffer (see
-- `common.spawn_tui`). The assertions read the drawn screen and drive it with typed
-- keys, so what is checked is what a user would see and do.
--
-- Snacks is out of scope on purpose: it is nix-nvim's dependency, not this repo's, so
-- `pick()` takes its `vim.ui.select` fallback here — which is also the path a user
-- without Snacks gets. Snacks visuals belong downstream, where Snacks exists.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")

-- ── a vault the real attach() path will accept ──────────────────────────────
local vault = c.work .. "/tui-vault"
vim.fn.mkdir(vault .. "/.loci", "p")
vim.fn.writefile({ "schema = 1" }, vault .. "/.loci/vault.toml")
vim.fn.writefile({ "# Note", "", "body" }, vault .. "/note.md")

-- a `loci-lsp` shim so the child spawns the fake through attach(), like t15
local bin = c.work .. "/tui-bin"
vim.fn.mkdir(bin, "p")
vim.fn.writefile({
  "#!" .. vim.fn.exepath("bash"),
  'exec python3 "' .. c.fakes .. '/fs_v2.py"',
}, bin .. "/loci-lsp")
vim.fn.setfperm(bin .. "/loci-lsp", "rwxr-xr-x")

local tui = c.spawn_tui({ file = vault .. "/note.md", bin_dir = bin })

-- ── the child is up and the buffer is drawn ─────────────────────────────────
local drawn, screen = tui:wait_for("body", 20000)
c.expect(drawn, "the child nvim should render the opened note:\n" .. screen)

local ready, s0 = tui:wait_attached(20000)
c.expect(ready, "the child's loci client should attach through the real attach() path:\n" .. s0)

-- ── a picker RENDERS, and a keypress answers it ─────────────────────────────
-- :LociWorkspaces -> workspaces/list -> pick() -> no Snacks -> vim.ui.select,
-- which draws a numbered list and waits for a number + Enter.
tui:feed(":LociWorkspaces\r")
local listed, s1 = tui:wait_for("Loci workspaces", 20000)
c.expect(listed, "the workspace picker must DRAW its prompt:\n" .. s1)
c.expect(s1:find("WS1", 1, true) ~= nil, "the picker must draw the server's row:\n" .. s1)

-- Answer it. This is the step that used to hang the harness.
tui:feed("1\r")
-- choosing a workspace pins it and opens the status hub, which is a second picker
local status, s2 = tui:wait_for("Loci status", 20000)
c.expect(status, "answering the picker must run the choice (status hub):\n" .. s2)
c.expect(s2:find("WS1", 1, true) ~= nil, "the status hub must name the pinned workspace:\n" .. s2)

-- ── a confirm RENDERS, and cancelling it aborts ────────────────────────────
-- The status hub's rows include the archive action, which goes through
-- preview_then_apply: preview -> vim.ui.select{Apply, Cancel}.
-- Dismiss the status picker with 0 — `vim.ui.select`'s fallback is `inputlist()`,
-- which takes a number and Enter. Escape alone leaves it waiting, and everything
-- typed after it lands in the prompt instead of the command line.
tui:feed("0\r")
local back, sb = tui:wait_for("body", 20000)
c.expect(back, "dismissing the picker must return to the buffer:\n" .. sb)

tui:feed(":LociAdopt\r")
local confirm, s3 = tui:wait_for("Apply", 20000)
c.expect(confirm, "preview-then-apply must DRAW its Apply/Cancel confirm:\n" .. s3)
c.expect(s3:find("Adopt", 1, true) ~= nil, "the confirm must describe what it would do:\n" .. s3)
c.expect(s3:find("Cancel", 1, true) ~= nil, "the confirm must offer Cancel:\n" .. s3)

tui:feed("2\r") -- Cancel
local settled, s4 = tui:wait_for("body", 20000)
c.expect(settled, "cancelling must return to the buffer, not hang:\n" .. s4)

-- ── an input prompt RENDERS and accepts typed text ─────────────────────────
tui:feed(":LociNote\r")
local prompt, s5 = tui:wait_for("Note name", 20000)
c.expect(prompt, "vim.ui.input must DRAW its prompt:\n" .. s5)
tui:feed("Typed Note\r")
-- fs_v2's documents/create fixture opens notes/x.md; either the new buffer or a
-- notice proves the typed text reached the client.
local created, s6 = tui:wait_for("x.md", 20000)
c.expect(created, "typing into the prompt must run the create flow:\n" .. s6)

tui:stop()
c.finish()
