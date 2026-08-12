-- t28 — realistic cardinality (004 F-08 / R4).
--
-- Every other scenario feeds the client 1-2 rows per wire. A real vault returns
-- thousands: the reference vault reports 4631 unmanaged diagnostics, 412 broken
-- links, 80 projects and a full 50-row search page. Nothing exercised the pickers
-- or the health renderer at that size, so truncation, ordering and per-row
-- formatting were all unverified at the only scale that matters.
--
-- This pins: every row survives to the picker (no silent cap), row order is the
-- server's, and each row is a single line -- a snippet or title containing a
-- newline must not be able to split one row into several.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))

local N_SEARCH, N_BROKEN, N_ORPHANS = 50, 412, 137

local search_rows, broken_rows, orphan_rows = {}, {}, {}
for i = 1, N_SEARCH do
  search_rows[i] = {
    string.format("notes/Note %d.md", i),
    "7527c974-673b-44f6-81ee-7a2214a96604",
    "managed",
    string.format("Note %d", i),
    -- real snippets are raw document text and DO contain newlines (004 F-05)
    string.format("# Note %d\n\nNote %d body. See [[Note %d]].\n", i, i, i + 1),
    -2.7062756914445156,
  }
end
for i = 1, N_BROKEN do
  broken_rows[i] = { string.format("notes/Note %d.md", i), string.format("Note %d", 4000 + i), "wikilink" }
end
for i = 1, N_ORPHANS do
  orphan_rows[i] = string.format("notes/Orphan %d.md", i)
end

local resp = {
  ["loci/search/text"] = { results = search_rows },
  ["loci/graph/broken_links"] = { rows = broken_rows },
  ["loci/graph/orphans"] = { rows = orphan_rows },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

local seen = {}
c.stub_pick(function(items, title)
  seen[title] = items
end)

-- ---- search at a full page --------------------------------------------------
vim.ui.input = function(_, cb)
  cb("project")
end
loci.search()
local got_search = c.wait_for(function()
  return seen["Loci search: project"] ~= nil
end, 10000)
c.expect(got_search, "the search picker must render at 50 rows")

local rows = seen["Loci search: project"] or {}
c.expect(#rows == N_SEARCH, "every search row must survive to the picker: got " .. #rows .. " of " .. N_SEARCH)
c.expect(
  rows[1] and rows[1].text:find("Note 1", 1, true) ~= nil,
  "row order must be the server's (first row first): " .. vim.inspect(rows[1])
)
c.expect(
  rows[#rows] and rows[#rows].path == string.format("notes/Note %d.md", N_SEARCH),
  "the LAST row must survive too (no silent truncation)"
)
-- the newline guard: a multi-line snippet must never split a picker row
for i, it in ipairs(rows) do
  if it.text:find("\n") then
    c.expect(false, "search row " .. i .. " contains a newline — it would break the picker: " .. it.text)
    break
  end
end

-- ---- health at 412 + 137 ----------------------------------------------------
loci.doctor()
local got_health = c.wait_for(function()
  return seen["Loci health"] ~= nil
end, 20000)
c.expect(got_health, "the health picker must render at scale")

local health = seen["Loci health"] or {}
local text = ""
for _, it in ipairs(health) do
  text = text .. (it.text or "") .. "\n"
end
c.expect(
  text:find("broken links (" .. N_BROKEN .. ")", 1, true) ~= nil,
  "the health summary must report the true broken-link count (" .. N_BROKEN .. "): " .. text
)
c.expect(
  text:find("orphans (" .. N_ORPHANS .. ")", 1, true) ~= nil,
  "the health summary must report the true orphan count (" .. N_ORPHANS .. "): " .. text
)
-- and the drill-down must carry every row, not a summary of them
for _, it in ipairs(health) do
  if it.text and it.text:find("broken links", 1, true) and it.action then
    it.action()
    break
  end
end
local drill = c.wait_for(function()
  return seen["Loci broken links"] ~= nil
end, 8000)
c.expect(drill, "drilling into a health group must open its own picker")
c.expect(
  #(seen["Loci broken links"] or {}) == N_BROKEN,
  "the drill-down must carry every row: got " .. #(seen["Loci broken links"] or {}) .. " of " .. N_BROKEN
)
c.finish()
