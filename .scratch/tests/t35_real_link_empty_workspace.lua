-- t35 — `:LociLinkFile` into an EMPTY workspace, against the REAL engine.
--
-- `link_file` is a read-modify-write: it reads the pinned workspace's view and PUTs
-- the whole composition back, because the engine's manifest is wholly-owned and a
-- PUT REPLACES it. A workspace with no document members therefore round-trips an
-- EMPTY list, and Lua cannot tell a list from a map. That matters now: loci-core
-- c34dc83 tightened `coerce_value`, and an empty list arriving as a JSON OBJECT is
-- refused at the boundary rather than iterated as zero keys. Probed against the real
-- loci-lsp at the pinned rev:
--
--   documents: {}  ->  {"ok": false, "error": {"kind": "InvalidRequestError",
--                                              "message": "expected a list, got {}"}}
--   documents: []  ->  ok
--
-- The client lands on the right side of that, for a reason worth writing down:
-- **neovim 0.12 encodes an unmarked empty table as `[]`**, not `{}` (objects are the
-- marked case — `vim.empty_dict()`). Measured, not assumed:
-- `vim.json.encode({})` -> `[]`. So no client change was needed — but the two halves
-- of that fact live in different repos, and nothing pinned either. This test does.
--
-- WHY THE REAL BINARY. `fs_v2.py` answers from fixtures and never builds a request
-- model, so no fake can refuse a malformed field. Only the engine's own coercion can.
--
-- t18 covers the same verb against the fake with a POPULATED view. This is the empty
-- one, which is what every freshly created workspace is.
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

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/note.md"))
local attached = c.wait_for(function()
  local cl = vim.lsp.get_clients({ name = "loci" })[1]
  return cl ~= nil and cl.initialized
end, 20000)
c.expect(attached, "the real loci-lsp should attach and initialize within 20s")

-- a brand-new workspace: no documents, no files
local wid
loci.read("workspaces/put", { name = "probe" }, function(value)
  wid = value and value.workspace_id
end)
local made = c.wait_for(function()
  return wid ~= nil
end, 15000)
c.expect(made, "the engine should create the workspace: " .. vim.inspect(c.notices))

vim.t.loci_workspace_id = wid
vim.env.PICK_MATCH = "implementation"
vim.ui.select = function(items, _, cb)
  cb(items[1]) -- "Apply"
end
loci.link_file()

-- The proof is the engine's own view: read it back and find the file we linked.
-- Asserting on the absence of a notice would also pass if the whole flow stalled.
local view_files, inflight = nil, false
local function refresh_view()
  if inflight then
    return
  end
  inflight = true
  loci.read("workspaces/get", { workspace_id = wid }, function(value)
    inflight = false
    view_files = (value and value.view and value.view.files) or {}
  end)
end

local linked = c.wait_for(function()
  refresh_view()
  for _, f in ipairs(view_files or {}) do
    if f[1] == "note.md" then
      return true
    end
  end
  return false
end, 20000)
c.expect(linked, "the linked file should be in the engine's workspace view: " .. vim.inspect(c.notices))

c.expect(
  not c.any_notice("expected a list"),
  "an empty member list must reach the engine as `[]`, never as `{}`: " .. vim.inspect(c.notices)
)
c.expect(
  not c.any_notice("InvalidRequestError"),
  "the put must not be refused at the boundary: " .. vim.inspect(c.notices)
)

c.finish()
