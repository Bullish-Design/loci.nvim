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

### Fixture fidelity — the one rule

> **A fixture value must have the same SHAPE, WIDTH, and VOCABULARY as the engine's, even when
> the test only cares about one field.**

This is not style. A statusline bug shipped to a real vault because `fs_v2` returned a 2-char
revision (`"r1"`) where the engine returns a 64-char content hash: the segment was green in CI at
2 chars and unusable at 64. The audit that followed
(`.scratch/projects/004-fakeserver-fidelity-audit/REPORT.md`) found twelve more instances of the
same bias — fixtures hand-authored to be *readable* rather than *representative*. Concretely:

* **Width** — revisions are 64-char hashes; ids are UUIDs. Never a short token.
* **Vocabulary** — only values the engine can actually emit. `identity_state` is
  `none|managed|degraded`; it is never `"ok"` (a value this file invented, which the whole suite
  would have validated). Cover the real spread of `kind`/`status`, not a convenient subset.
* **Shape** — every field the engine sends, including ones the client currently ignores
  (`saveResult.uri`, `workspaces/list[].documents`). Omitting a field silently removes it from
  the design space: no test can tell "we chose not to use it" from "we cannot".
* **Content** — real text, with the newlines real text contains. Search snippets are raw document
  bodies; link columns are resolved target names (`"Note 4538"`), never wikilink syntax.

**This rule is enforced, not merely stated.** `fixtures.json` holds the engine's contract — key
sets, row arities, enum vocabularies, the revision width — and `fs_v2.py` validates its `DEFAULTS`
against it at startup, exiting non-zero with a diff-style report on any drift. Since every scenario
spawns the fake, a violation fails the whole suite at once instead of silently licensing a lying
fixture. Verified to catch: a revived `identity_state: "ok"`, a 2-char revision (the original bug),
a non-UUID id, and a dropped `workspaces/list` field.

### Capturing ground truth — two routes, because there are two kinds of wire

| Capture | Route | Covers |
|---|---|---|
| `capture-fixtures.sh <vault> [--write-contract]` | the `loci` **CLI** | reads: `documents/*`, `workspaces/*`, `search/*`, `graph/*`, `maintenance/refresh` |
| `capture-effects.py [--vault <root>] [--write-contract]` | raw JSON-RPC to a live **`loci-lsp`** | effects: every mutating wire + its preview, all five `loci/saveResult` outcomes, `textDocument/codeAction`, `loci.action.execute` |

For a READ the CLI envelope **is** the wire envelope, so the CLI is honest ground truth. For an
EFFECT it is not: `loci --json documents/create` returns a `CommandPreview`
(`{command, changes, refusals, _committed: false}`) and does not commit at all, while the LSP host
commits and sends the `SourceCommit` (`{document, commit: {...}, revision}`). Project 004 captured
effects from the CLI and validated the fake against a shape the client never sees; two live bugs
(F-14, F-15) and one invented enum value (F-16) came out of that single blind spot. **Never write an
effect fixture from the CLI.**

`capture-effects.py` builds a throwaway vault, drives every effect over the wire, and prints the
envelopes; `--write-contract` merges the observed key sets, the `SourceCommit` field set, the
`saveResult` required/optional split and its `reason` vocabulary, and the code-action shapes into
`fixtures.json`. Run either capture after an engine change rather than hand-editing values back into
place — hand-editing is how the fixtures drifted in the first place.

**Barriers matter when capturing.** LSP notifications are queued, so a bare `didOpen` has NOT been
processed when the call returns. Writing a file straight after sending `didOpen` lets the server
read the *new* bytes as its CAS base, and every conflict probe comes back `committed` — the capture
races itself and reports the happy path. `capture-effects.py::Server.sync()` issues a request as a
barrier between notification and file write for exactly this reason.

**A probe is not evidence until it can tell "no reply" from "empty reply".** The `codeAction
returned 0` finding that opened project 005 was a probe artifact: the drive passed
`vim.diagnostic.get(0)` — `vim.Diagnostic` rows, which carry `lnum`/`col` and no `range` — as
`context.diagnostics`. pygls raises `JsonRpcInvalidParams` while *structuring* the message, before
dispatch, so the server never answers at all, and the probe recorded the missing reply as `0
actions`. Always record whether the reply arrived, separately from what it contained.

Two override keys exist so the fake can misbehave on purpose (a fake that always succeeds cannot
test failure): `"__drop__": [method, ...]` never answers those methods, and an override carrying
an `"ok"` key is sent as the whole envelope, making `{ok: false, error}` refusals expressible.

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
| link-a-file read-modify-write into `workspaces/put` | t18 |
| graph pickers: neighbors / traversal / project members | t19, t20 |
| document move + adopt (preview-then-apply) | t21, t22 |
| palette mirrors the registry surface | t23 |
| `unmanaged` escape hatch refreshes attached buffers | t24 |
| statusline segment width + staleness marker | t25 |
| refused envelope (`ok: false`) on reads and effects | t26 |
| doctor settles on a failing / unanswered leg | t27 |
| picker + health rendering at real cardinality | t28 |
| refused effect (`commit.status`) is reported | t29 |
| refused save on `:w` of a new file names file, reason, remedy | t30 |
| diagnostics: PULL route, severity map, range map | t31 |

The old t09–t21 (palette args, activation, deactivation, editor_state, git writeback, doctor,
real-server fullstack) are **deleted** — they encoded engine capabilities V2 removed (arch §18).
The real-server fullstack returns as **t17** against the new engine.
