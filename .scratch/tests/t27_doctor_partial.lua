-- t27 — LociDoctor must settle even when a leg does not (004 F-09).
--
-- `M.doctor()` fans out four graph requests and joins them into one picker. It used
-- to decrement its counter ONLY in the success callback, so a refusing leg (whose
-- `cb` never runs) or an unanswered leg left the join stranded: no picker, no notice,
-- the command silently did nothing. fs_v2 could not reach either case — it always
-- answered everything with ok:true — so this is also the regression test for the
-- fake's new `__drop__` / refusal-envelope modes.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")
c.capture_notify()
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))

-- one leg REFUSES (never calls cb), one leg is DROPPED (never answers at all)
local resp = {
  ["loci/graph/ambiguous_links"] = {
    ok = false,
    error = { kind = "VaultPolicyError", message = "ambiguity scan unavailable" },
  },
  ["__drop__"] = { "loci/graph/orphans" },
}
local f = io.open(c.work .. "/respA.json", "w")
f:write(vim.json.encode(resp))
f:close()
c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", c.work .. "/respA.json")
vim.wait(1000)

-- capture what the health picker renders
local picked = nil
c.stub_pick(function(items, prompt)
  if prompt == "Loci health" then
    picked = items
  end
end)

loci.doctor()

-- the refused leg surfaces its own error notice immediately
c.expect(
  c.wait_for(function()
    return c.any_notice("ambiguity scan unavailable")
  end, 8000),
  "the refused leg must surface its error: " .. vim.inspect(c.notices)
)

-- The dropped leg never answers, so the join settles on the deadline. The picker
-- MUST still render (with the legs that did arrive) rather than silently vanish.
local rendered = c.wait_for(function()
  return picked ~= nil
end, 25000)
c.expect(rendered, "the health picker must render even when a leg never answers")
c.expect(
  c.any_notice("INCOMPLETE"),
  "an incomplete health report must say so, naming the unanswered leg: " .. vim.inspect(c.notices)
)
c.expect(
  c.any_notice("orphans"),
  "the incompleteness notice must name the dropped leg (orphans): " .. vim.inspect(c.notices)
)
if picked then
  -- broken_links + missing_attachments answered normally, so their groups are present
  local text = ""
  for _, it in ipairs(picked) do
    text = text .. (it.text or "") .. "\n"
  end
  c.expect(text:find("broken links", 1, true) ~= nil, "the answered legs must still render: " .. text)
end
c.finish()
