-- common.lua — shared bootstrap for the loci.nvim headless test suite.
--
-- Loaded FIRST by the runner (`lua dofile('.../common.lua')`), before each test
-- file. Responsibilities:
--   * put the plugin on the runtimepath (env LOCI_PLUGROOT = repo root),
--   * stub Snacks (the picker) so `pick()` confirm fires without a UI,
--   * provide `expect`/`finish` (self-asserting tests print `RESULT: PASS/FAIL`),
--   * record `vim.notify` messages so tests can assert on notices,
--   * helpers: fake-server spawn, resession setup, path/string utils.

local M = {}

M.plugin_root = vim.env.LOCI_PLUGROOT or error("LOCI_PLUGROOT not set (run via run-tests.sh)")
vim.opt.rtp:prepend(M.plugin_root)

M.tests_dir = vim.env.LOCI_TESTS or error("LOCI_TESTS not set (run via run-tests.sh)")
M.work = vim.env.LOCI_WORK or error("LOCI_WORK not set (run via run-tests.sh)")
M.repo_a = vim.env.LOCI_REPO_A or error("LOCI_REPO_A not set (run via run-tests.sh)")
M.repo_b = vim.env.LOCI_REPO_B or error("LOCI_REPO_B not set (run via run-tests.sh)")
M.sessions = vim.env.LOCI_SESSIONS or (M.work .. "/sessions")
M.fakes = M.tests_dir .. "/fakeservers"
M.vendor = M.tests_dir .. "/vendor"

-- ---- assertions -------------------------------------------------------------

local failures = {}

function M.expect(cond, msg)
  if not cond then
    failures[#failures + 1] = msg or "assertion failed"
  end
end

-- Print PASS/FAIL, stop any lingering loci clients (nvim's exit does NOT close
-- the stdin of its detached LSP children, so without this every test orphans its
-- fakeserver processes), then exit. Called at the end of every test; the runner
-- greps the RESULT line and treats anything else (crash/hang/timeout) as a failure.
function M.finish()
  if #failures == 0 then
    io.write("RESULT: PASS\n")
  else
    io.write("RESULT: FAIL — " .. table.concat(failures, "; ") .. "\n")
  end
  io.flush()
  for _, cl in ipairs(vim.lsp.get_clients({ name = "loci" })) do
    pcall(function()
      cl:stop(true)
    end)
  end
  vim.cmd("qa!")
end

-- ---- notify capture ---------------------------------------------------------

-- Wrap vim.notify so tests can assert on the client's notices (call AFTER
-- require("loci") is not required — vim.notify is looked up at call time).
local orig_notify = vim.notify

function M.capture_notify()
  M.notices = {}
  vim.notify = function(msg, level, opts)
    M.notices[#M.notices + 1] = tostring(msg)
    return orig_notify(msg, level, opts)
  end
end

function M.any_notice(fragment)
  for _, n in ipairs(M.notices or {}) do
    if n:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

-- ---- Snacks stub ------------------------------------------------------------

-- The client's `pick()` calls Snacks.picker.pick; headless there is no UI, so the
-- stub confirms immediately. Selection: the first item whose .text matches
-- PICK_MATCH (plain substring), else items[PICK_INDEX], else items[1]. Tests that
-- need a mid-flow side effect (buffer switch, file write) re-stub `pick` locally.
_G.Snacks = {
  picker = {
    pick = function(opts)
      if not opts.items or #opts.items == 0 then
        return
      end
      local item
      local match = vim.env.PICK_MATCH
      if match then
        for _, it in ipairs(opts.items) do
          if it.text and it.text:find(match, 1, true) then
            item = it
            break
          end
        end
      end
      if not item then
        item = opts.items[tonumber(vim.env.PICK_INDEX) or 1]
      end
      opts.confirm({ close = function() end }, item)
    end,
    files = function() end,
  },
}

-- Replace the picker with an OBSERVER: `fn(items, title)` runs for every pick and
-- nothing is auto-confirmed. Use this when the assertion is about what the user
-- would be shown (that a picker rendered at all, and with which rows) rather than
-- about what happens after choosing a row.
function M.stub_pick(fn)
  _G.Snacks.picker.pick = function(opts)
    fn(opts.items or {}, opts.title)
  end
end

-- ---- helpers ----------------------------------------------------------------

function M.spawn_fake(root, script, ...)
  local cmd = { "python3", script, ... }
  vim.lsp.start({ name = "loci", cmd = cmd, root_dir = root })
end

-- Poll fn() until true (or timeout_ms elapses). Uses vim.wait so LSP callbacks run.
function M.wait_for(fn, timeout_ms)
  local t = 0
  while t < timeout_ms do
    if fn() then
      return true
    end
    vim.wait(50)
    t = t + 50
  end
  return fn()
end

-- Real resession (vendored): setup with a per-test session dir, autosave OFF so
-- only explicit save_tab/save calls write files (deterministic assertions).
function M.setup_resession()
  vim.opt.rtp:prepend(M.vendor .. "/resession.nvim")
  vim.fn.mkdir(M.sessions, "p")
  require("resession").setup({ dir = M.sessions, autosave = { enabled = false } })
end

-- Abs path of a resession session file (resession resolves `dir` under
-- stdpath('data')).
function M.session_file(name)
  local ok, util = pcall(require, "resession.util")
  if ok and util.get_session_file then
    return util.get_session_file(name)
  end
  return vim.fn.stdpath("data") .. "/" .. M.sessions:gsub("^/", "") .. "/" .. name .. ".json"
end

-- Read a text file (nil if missing).
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

return M
