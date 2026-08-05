# loci.nvim — headless regression suite (V2 wire)

Hermetic, deterministic headless tests for the thin `loci` LSP client
(`lua/loci/init.lua`) **against the V2 wire contract** — see
`.scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md`. Every test is one
`nvim --headless` invocation against `fakeservers/fs_v2.py`, a **reference implementation of
that contract** (registry feature methods `loci/<wire>`, preview routes, `loci.action.execute`,
pull diagnostics, `loci/saveResult`). Because the fakes implement the *contract* — not a mock of
the plugin — this suite gates the client against what the engine host must implement, without
needing the real engine (which is being restored in loci-core, project 002 P0.2).

## Run

```bash
.scratch/tests/run-tests.sh          # the full suite (≈1 min)
.scratch/tests/run-tests.sh t05      # filter: run tests whose name matches
```

Requires on PATH: `nvim` (0.12.x — override with `NVIM=/path/to/nvim`), `python3`, `git`,
`timeout`. **t17 (real-server smoke) requires the REAL `loci-lsp` + `loci` binaries** (the V2
engine's build): the runner falls back to `/etc/profiles/per-user/andrew/bin`, and if the
on-PATH `loci` lacks the `init` verb (stale fleet profile), it builds this flake's own
`.#loci-lsp` via `nix` and prepends it. The nix check does the same via the checkPhase PATH.
Every other test is hermetic against the fakes.

## How it works

- Each test runs in a **fresh sandbox** (`mktemp`): `repoA` (git branch `feature-x`) and `repoB`
  (branch `main-b`) are recreated per test. Fixture vaults have **no** `.loci/` (so the attach
  autocmd no-ops); tests that need the real attach path create the vault themselves — t15 via a
  shimmed `.loci/vault.toml`, t17 via the real `loci init` CLI verb.
- The client plugin is loaded from the repo root (`LOCI_PLUGROOT`); `common.lua` bootstraps the
  runtimepath, stubs Snacks (the picker), records `vim.notify`, and provides `expect`/`finish`.
- A test **passes iff its output contains `RESULT: PASS`**; a crash, hang (180s timeout), or
  failed assertion fails the run and the runner exits non-zero.
- `vim.ui.input`/`vim.ui.select` are stubbed per test where a prompt is exercised; picker
  selection is driven by `PICK_MATCH`/`PICK_INDEX` (see `common.lua`).

## Fakeservers (`fakeservers/`)

| File | Serves |
|---|---|
| `fs_v2.py` | the **V2 wire contract**: LSP lifecycle (initialize with object-form `textDocumentSync` incl. `save`), `textDocument/diagnostic` pull + `publishDiagnostics` push, `textDocument/codeAction` (data + `command: loci.action.execute`), `workspace/executeCommand` (`loci.action.execute`, `loci.test.crash`), the `loci/<wire>` feature methods + `/preview` routes with the `{ok, value}` envelope (+ `_revision`/`_consistency`), and the `loci/saveResult` notification. Per-test overrides via a JSON response file (argv[2] / `FS_RESPONSE`); diagnostics to push via argv[3] / `FS_DIAGNOSTICS`; every request logged to argv[1] / `FS_LOG`. |
| `fs_slow.py` | delayed `initialize` (attach-latency notice test). |

Every fakeserver MUST do BOTH of these or it leaks processes when nvim dies:

1. **exit on stdin EOF** — `if not chunk: sys.exit(0)` in the header loop. When the spawning nvim
   exits/crashes, its pipe closes and the server gets EOF; without the guard it busy-spins on
   `read(1)` forever.
2. **handle the `exit` notification** — `sys.exit(0)` when `msg.method == "exit"`. nvim's
   graceful `client:stop()` sends shutdown/exit but KEEPS stdin open, so EOF never arrives; only
   the `exit` request tells the server to die.

`t15` reaches the client's REAL `attach()` path by placing a `loci-lsp` shim (first on PATH, and
only for t15) that execs `fs_v2.py` — so the F9 `on_error`/`on_exit` handlers (which only
`attach()` registers) are what the assertions exercise. `t17` reaches the SAME attach path with
the REAL binary (no shim for t17) and runs a full round trip: `loci init` bootstraps the vault,
the real pygls host answers `loci/documents/create`, the file lands on disk with the canonical
`loci:` region, and the D-028 name refusal arrives as a typed envelope notice.

## What the suite pins (scenario → test)

| Scenario | Test |
|---|---|
| module load, 10 commands, no early client | t01 |
| no-client / server-starting notices | t02, t03 |
| vault-not-initialized refusal (`vault.toml` missing) | t04 |
| workspace switcher (list→pin→get) | t05, t06 |
| documents/create (note/daily templates) opens real path | t07, t08 |
| documents/list kind=project browser | t09 |
| health hub: maintenance/refresh + graph queries | t10 |
| code-action dispatch via `loci.action.execute` | t11 |
| `unmanaged` diagnostic filter (D-047/arch §13) | t12 |
| CAS save conflict via `loci/saveResult` (D-041) | t13 |
| archive preview-then-apply (D-032) | t14 |
| server-death hygiene through real attach (shim) | t15 |
| workspaces/put create + pin (preview-first) | t16 |
| **REAL engine**: init → attach → create → open → refusal (V2) | t17 |

The old t09–t21 (palette args, activation, deactivation, editor_state, git writeback, doctor,
real-server fullstack) are **deleted** — they encoded engine capabilities V2 removed (arch §18).
The real-server fullstack returns as **t17** against the new engine.
