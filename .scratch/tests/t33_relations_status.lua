-- t33 — the capabilities the client had no surface for (005 item 4).
--
-- The engine registers 24 wires; five had no `:Loci*` verb. Four now do:
-- `relations/add_project`, `relations/remove_project`, `documents/set_status` and
-- `documents/format_owned`. `documents/preview_adoption` stays engine-only — it
-- duplicates `documents/adopt/preview` in a shape (`{preview: AdoptionPreview}`)
-- that `summarize_preview` cannot render, for no user-visible gain.
--
-- Project membership was the real gap: a project is just a document whose kind is
-- `project`, membership lives in the member's owned `loci:` region, and nothing in
-- the editor could write it.
--
-- What this pins: the right wire, the right params, and — for set_status — that the
-- status vocabulary comes from the SERVER's data, never a hardcoded client list.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()

vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA")
vim.wait(1000)

-- preview_then_apply confirms through vim.ui.select; auto-Apply.
vim.ui.select = function(items, _opts, cb)
  for _, it in ipairs(items) do
    if tostring(it):lower():find("apply") then
      return cb(it)
    end
  end
  cb(items[1])
end

local function log()
  return c.read_file(c.work .. "/logA") or ""
end

-- ── add to project ─────────────────────────────────────────────────────────
-- the project picker rows come from documents/list kind=project (fs_v2 ships
-- projects/p1.md titled "P1"); PICK_MATCH is unset, so the stub takes items[1].
vim.cmd("LociAddProject")
local added = c.wait_for(function()
  return log():find("req loci/relations/add_project ", 1, true) ~= nil
end, 5000)
c.expect(added, "LociAddProject must reach relations/add_project: " .. log())
c.expect(
  log():find("req loci/relations/add_project/preview", 1, true) ~= nil,
  "membership must go through the declared preview route (D-032): " .. log()
)
c.expect(
  log():find('"document": "note.md"', 1, true) ~= nil and log():find('"project": "projects/p1.md"', 1, true) ~= nil,
  "the request must carry {document, project}: " .. log()
)

-- ── remove from project ────────────────────────────────────────────────────
vim.cmd("LociRemoveProject")
local removed = c.wait_for(function()
  return log():find("req loci/relations/remove_project ", 1, true) ~= nil
end, 5000)
c.expect(removed, "LociRemoveProject must reach relations/remove_project: " .. log())

-- ── format owned metadata ──────────────────────────────────────────────────
vim.cmd("LociFormat")
local formatted = c.wait_for(function()
  return log():find("req loci/documents/format_owned ", 1, true) ~= nil
end, 5000)
c.expect(formatted, "LociFormat must reach documents/format_owned: " .. log())
c.expect(
  log():find('"ref": "note.md"', 1, true) ~= nil,
  "format_owned takes {ref}, not {path}: " .. log()
)

-- ── set status: the vocabulary is the SERVER's ─────────────────────────────
-- fs_v2's documents/list spans the real spread (active / waiting / duplicated).
-- The picker must offer those, deduped and sorted, plus a free-text escape — and
-- must NOT invent a value the vault is not using.
local offered
c.stub_pick(function(items, title)
  offered = { items = items, title = title }
end)
vim.cmd("LociSetStatus")
local shown = c.wait_for(function()
  return offered ~= nil
end, 5000)
c.expect(shown, "LociSetStatus must offer a status picker")
if offered then
  local texts = {}
  for _, it in ipairs(offered.items) do
    texts[#texts + 1] = it.text
  end
  c.expect(
    vim.deep_equal(texts, { "active", "duplicated", "waiting", "＋ other…" }),
    "statuses must come from documents/list, deduped and sorted, with a free-text escape: "
      .. vim.inspect(texts)
  )
  c.expect(
    offered.title:find("note.md", 1, true) ~= nil,
    "the picker must name the document it will change: " .. tostring(offered.title)
  )
  -- Choosing one must reach the wire. Restore the auto-confirming picker (it takes
  -- items[1] = "active") and run the command for real.
  _G.Snacks.picker.pick = function(opts)
    opts.confirm({ close = function() end }, opts.items[1])
  end
  vim.cmd("LociSetStatus")
  local sent = c.wait_for(function()
    return log():find("req loci/documents/set_status ", 1, true) ~= nil
  end, 5000)
  c.expect(sent, "choosing a status must reach documents/set_status: " .. log())
  c.expect(
    log():find('"ref": "note.md"', 1, true) ~= nil and log():find('"status": "active"', 1, true) ~= nil,
    "the request must carry {ref, status}: " .. log()
  )
end
c.finish()
