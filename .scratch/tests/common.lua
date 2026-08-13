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

-- ---- TUI driver ---------------------------------------------------------------
--
-- Everything above drives the client by CALLING it. That leaves a real gap: it
-- cannot see what a user sees, and it cannot press a key. `vim.ui.select` is the
-- sharp edge — headless it blocks forever, so every flow that confirms through it
-- (preview-then-apply, every picker on a machine without Snacks) was exercised only
-- by stubbing the prompt away. A stubbed prompt proves the callback runs; it proves
-- nothing about whether the prompt renders or whether answering it works.
--
-- The driver spawns a CHILD nvim inside a terminal buffer of this (headless) one.
-- The terminal buffer is a real libvterm screen, so the child runs its ordinary TUI:
-- `nvim_buf_get_lines` reads what is actually drawn, and `chansend` types into it.
-- No pty helper, no extra dependency, no escape-sequence parsing — nvim already
-- owns both halves.
--
-- SCOPE. This repo cannot render Snacks: the picker is nix-nvim's dependency, not
-- loci.nvim's, and `pick()` falls back to `vim.ui.select` when it is absent. What is
-- verifiable here is the fallback path — which is also what a user without Snacks
-- gets — plus `vim.ui.input`, notifications, and keyboard confirmation. Snacks
-- *visuals* stay out of scope and belong downstream, where Snacks exists.

local Tui = {}
Tui.__index = Tui

-- Spawn a child nvim on `file`, with `plugin_root` on its runtimepath and `bin_dir`
-- first on PATH (put a `loci-lsp` shim there to reach the real attach path).
function M.spawn_tui(opts)
  local self = setmetatable({}, Tui)
  vim.cmd("enew")
  self.buf = vim.api.nvim_get_current_buf()
  local nvim = opts.nvim or vim.v.progpath
  -- `require("loci")` must run BEFORE the file is opened: the attach autocmd is
  -- BufReadPost/BufNewFile, and a file passed as argv is already loaded by the time
  -- `-c` commands run — so the plugin would register its autocmd after the only
  -- event that would have fired it, and nothing ever attaches. Open the file with a
  -- second `-c` instead, which is also what a user does.
  local cmd = {
    nvim, "-u", "NONE", "--cmd", "set rtp+=" .. M.plugin_root,
    "-c", "lua require('loci')",
    "-c", "edit " .. vim.fn.fnameescape(opts.file),
  }
  self.job = vim.fn.jobstart(cmd, {
    term = true,
    env = {
      PATH = (opts.bin_dir and (opts.bin_dir .. ":") or "") .. vim.env.PATH,
      -- keep the child out of the parent's (and the user's) state
      HOME = opts.home or M.work,
      XDG_DATA_HOME = M.work .. "/xdg-data",
      XDG_STATE_HOME = M.work .. "/xdg-state",
      XDG_CACHE_HOME = M.work .. "/xdg-cache",
      NVIM = "", -- else the child treats this nvim as its parent and refuses the TUI
      NVIM_LISTEN_ADDRESS = "",
    },
  })
  return self
end

-- The child's screen, as one string (blank right margin trimmed per line).
function Tui:screen()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub("%s+$", ""))
  end
  return table.concat(lines, "\n")
end

-- Type into the child. `keys` is literal text; use "\r" for Enter.
function Tui:feed(keys)
  vim.fn.chansend(self.job, keys)
end

-- Wait until the child's screen contains `text` (plain substring). Returns
-- true, or false plus the last screen seen.
function Tui:wait_for(text, timeout_ms)
  local last = ""
  local ok = M.wait_for(function()
    last = self:screen()
    return last:find(text, 1, true) ~= nil
  end, timeout_ms or 15000)
  return ok, last
end

-- Block until the child's loci client has finished initialize. A picker only draws
-- once a reply arrives, so feeding `:LociWorkspaces` the moment the buffer appears
-- races the attach and the test flakes. The child does the waiting (one `vim.wait`
-- inside it) and prints a sentinel; the parent watches for the sentinel.
function Tui:wait_attached(timeout_ms)
  local budget = timeout_ms or 20000
  self:feed(
    ":lua vim.wait(" .. budget .. ", function() local c = vim.lsp.get_clients({name='loci'})[1];"
      .. " return c ~= nil and c.initialized end, 100); print('LOCI-READY')\r"
  )
  local ok, screen = self:wait_for("LOCI-READY", budget + 5000)
  self:feed("\r") -- dismiss the "Press ENTER" prompt the print leaves behind
  return ok, screen
end

function Tui:stop()
  pcall(vim.fn.jobstop, self.job)
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
