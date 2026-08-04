# loci.nvim — headless regression suite

Hermetic, deterministic headless tests for the thin `loci` LSP client
(`lua/loci/init.lua`). Ported from the ephemeral review harness that verified the
F1–F12 fixes; every test is one `nvim --headless` invocation against either a
Python JSON-RPC fakeserver or the real `loci-lsp`, with real fixture git vaults.

## Run

```bash
.scratch/tests/run-tests.sh          # the full suite (≈80s, includes ~8s of real-server init)
.scratch/tests/run-tests.sh t05      # filter: run tests whose name matches
.scratch/tests/run-tests.sh f5       # the Task-1 F5 tests
```

Requires on PATH: `nvim` (0.12.x — override with `NVIM=/path/to/nvim`), `python3`,
`git`, `timeout`. The real `loci-lsp` binary is needed for exactly one test
(`t17`); the runner also looks in `/etc/profiles/per-user/andrew/bin`.

## How it works

- Each test runs in a **fresh sandbox** (`mktemp`): `repoA` (git branch
  `feature-x`) and `repoB` (branch `main-b`) are recreated per test, so a test can
  never leak a `.loci` marker dir / session file into the next one. (A stray
  marker dir makes the attach autocmd spawn a second REAL client and pollute
  results — that bit the review.)
- The client plugin is loaded from the repo root (`LOCI_PLUGROOT`); `common.lua`
  bootstraps the runtimepath, stubs Snacks (the picker), records
  `vim.notify`, and provides `expect`/`finish`.
- A test **passes iff its output contains `RESULT: PASS`**; a crash, hang (180s
  timeout), or failed assertion fails the run and the runner exits non-zero.
- Session tests use the **real resession.nvim v1.2.0** and **real haunt.nvim
  v1.2.0**, vendored under `vendor/` (rtp entries). `wayfinder` is **stubbed** to
  the two API functions the client calls (`trail_active_name`, `trail_save_named`
  in deactivate; `trail_load_named` in activation) — the real plugin's trail
  backend needs its interactive layout/picker stack and does not track an active
  trail headless (verified); the client's calls are pcall-guarded, so the stub
  exercises exactly the surface the client uses. The review harness stubbed it
  the same way.

## Fakeservers (`fakeservers/`)

Content-Length-framed LSP over stdio; one per scenario shape:

| File | Serves |
|---|---|
| `fs_index.py` | read hubs (`project.index`/`workspace.index`); `loci.test.crash` → dies with exit 3 (F9 abnormal exit) |
| `fs_status.py` | status-hub reads (`workspace.current/summary/get`) + deactivate plan + command log |
| `fs_doctor.py` | doctor report (one fixable `missing_loci_id`) + command log |
| `fs_activate.py` | activation plans read from a per-test response file + command log |
| `fs_commands.py` | crafted `loci/commands` (note.create arg shapes, start-work) + note/plan responses |
| `fs_slow.py` | delayed `initialize` (attach-latency notice test) |

`t16` reaches the client's REAL `attach()` path by placing a `loci-lsp` shim
(first on PATH) that execs `fs_index.py` — so the F9 `on_error`/`on_exit`
handlers (which only `attach()` registers) are what the assertions exercise.

## Coverage map

| Test | Finding / behavior |
|---|---|
| `t01_module_load` | 8 user commands registered; no client before a vault file |
| `t02_no_client_warn` | no-client warn ("open a file inside a loci vault") |
| `t03_latency_notice` | "server still starting" while the only client initializes (Task 3a) |
| `t04_single_vault` | project hub opens in the one vault |
| `t05_two_vault_anchor` | F1 root anchoring: opens in the CURRENT vault, not the first client |
| `t06_midflow_switch` | F3 pinning: open stays in the entry vault across a mid-flow buffer switch |
| `t07_pinned_checktime` | checktime reloads the PINNED buffer, not the current one |
| `t08_f5_palette_create` | F5: palette `note.create` opens the created note |
| `t09_f5_startwork_open` | F5: palette `start-work` opens `primary_content_path` after resession.load churn |
| `t10_activation_tab` | activation writeback reaches the RIGHT vault through a tab-scoped load |
| `t11_activation_global` | global-session guard: reset=false, buffer survives, warning fires |
| `t12_deactivate_happy` | F2/F4/F8: deactivate saves session + trail, clears marker |
| `t13_deactivate_wrong_tab` | wrong-tab/trail guard: nothing clobbered, marker still cleared |
| `t14_prompt_args` | F12: required-cancel notifies; empty-vocab never opens a picker |
| `t15_f7_unsaved_warning` | F7: unsaved-buffer clobber warning fires |
| `t16_f9_server_death` | F9 through real `attach()`: graceful silent; abnormal exit → hint + marker clear |
| `t17_f9_real_server` | F9 end-to-end with the real `loci-lsp` (~4s init) |
| `t18_f6_git` | F6: first activation records the vault root's branch; recorded worktree wins |
| `t19_code_action_dispatch` | `client:exec_cmd` → `vim.lsp.commands` interception + `ctx.bufnr` (the fleet's tiny-code-action path) |
| `t20_real_fullstack` | REAL engine: `repository.init` → `M.daily()` → created note written + opened |
| `t21_real_plugins_activation` | REAL haunt `change_data_dir` + resession load + wayfinder trail in one activation |
