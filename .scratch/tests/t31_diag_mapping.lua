-- t31 — diagnostic PULL, severity mapping and range mapping (005 item 8).
--
-- t12 and t24 both drive the PUSH route (`publishDiagnostics` after didOpen) and both
-- assert on `code` alone. Two things went untested as a result:
--
--   * the PULL route (`textDocument/diagnostic` -> `{kind: "full", items}`) is what a
--     real session uses — the engine advertises `diagnosticProvider`, so nvim pulls and
--     never pushes. The client wraps BOTH handlers; only the push wrapper had a test
--     with its own payload.
--   * severity and range. The engine maps four severities (adapter._SEV) and real UTF-16
--     spans (D-041); the fixtures only ever carried severity 2 and 3, and nothing checked
--     that a span survives the trip into `vim.diagnostic`. A client that dropped ranges
--     would have passed the whole suite.
--
-- Real codes and severities, from loci-core features/actions.py::SEVERITY_BY_CODE.
local c = dofile(vim.env.LOCI_TESTS .. "/common.lua")
local loci = require("loci")

local S = vim.diagnostic.severity
local rows = {
  -- code, LSP severity, expected vim severity, range
  { "yaml_parse_error", 1, S.ERROR, 0, 0, 0, 3 },
  { "missing_target", 2, S.WARN, 2, 1, 2, 12 },
  { "unmanaged", 3, S.INFO, 0, 0, 0, 0 },
  { "degraded_identity", 4, S.HINT, 1, 4, 3, 7 },
}
local diags = {}
for _, r in ipairs(rows) do
  diags[#diags + 1] = {
    range = {
      start = { line = r[4], character = r[5] },
      ["end"] = { line = r[6], character = r[7] },
    },
    severity = r[2],
    code = r[1],
    message = r[1],
    source = "loci",
  }
end
local f = io.open(c.work .. "/diags.json", "w")
f:write(vim.json.encode(diags))
f:close()

-- a buffer with enough lines for the ranges above to land inside it
vim.cmd("edit " .. vim.fn.fnameescape(c.repo_a .. "/note.md"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line zero", "line one", "line two here", "line three" })
local bufnr = vim.api.nvim_get_current_buf()

c.spawn_fake(c.repo_a, c.fakes .. "/fs_v2.py", c.work .. "/logA", "", c.work .. "/diags.json")
vim.wait(1000)

-- ── the PULL route, driven explicitly ───────────────────────────────────────
-- nil handler -> nvim routes the reply through vim.lsp.handlers, i.e. the client's
-- wrapper, exactly as an editor-initiated pull does.
local client = vim.lsp.get_clients({ name = "loci", bufnr = bufnr })[1]
c.expect(client ~= nil, "the fake client should be attached")
if client then
  client:request("textDocument/diagnostic", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }, nil, bufnr)
end

local got = c.wait_for(function()
  return #vim.diagnostic.get(bufnr) > 0
end, 5000)
c.expect(got, "the pull route must deliver diagnostics")

local log = c.read_file(c.work .. "/logA") or ""
c.expect(
  log:find("req textDocument/diagnostic", 1, true) ~= nil,
  "the client must reach the server over the PULL route: " .. log
)

local by_code = {}
for _, d in ipairs(vim.diagnostic.get(bufnr)) do
  by_code[tostring(d.code)] = d
end

-- `unmanaged` is informational and filtered by default — on the pull route too.
c.expect(by_code["unmanaged"] == nil, "the pull wrapper must filter `unmanaged` like the push wrapper does")

for _, r in ipairs(rows) do
  local code, want_sev, l0, c0, l1, c1 = r[1], r[3], r[4], r[5], r[6], r[7]
  if code ~= "unmanaged" then
    local d = by_code[code]
    c.expect(d ~= nil, code .. " must survive the filter")
    if d then
      c.expect(
        d.severity == want_sev,
        string.format("%s severity: got %s want %s", code, tostring(d.severity), tostring(want_sev))
      )
      c.expect(
        d.lnum == l0 and d.col == c0 and d.end_lnum == l1 and d.end_col == c1,
        string.format(
          "%s range: got (%s,%s)-(%s,%s) want (%d,%d)-(%d,%d)",
          code, tostring(d.lnum), tostring(d.col), tostring(d.end_lnum), tostring(d.end_col), l0, c0, l1, c1
        )
      )
    end
  end
end

-- With the escape hatch on, the SAME pull must deliver the informational row too.
vim.cmd("LociToggleUnmanaged")
local shown = c.wait_for(function()
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.code == "unmanaged" then
      return true
    end
  end
  return false
end, 6000)
c.expect(shown, "with the flag set, the pull route must deliver `unmanaged` as well")
c.finish()
