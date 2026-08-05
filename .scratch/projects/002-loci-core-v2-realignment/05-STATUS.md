# 05 — Status: engine LSP host landed; loci.nvim aligned

**Date:** 2026-08-05

## The engine side shipped

loci-core `main` @ `4a8d5e2` ("test(lsp): codec unit tests + pytest-lsp host suite +
raw-stdio wire suite + loci init tests") implements project 32 exactly as specified:

- `apps/lsp/server.py` — the pygls transport (object-form `textDocumentSync` derived by pygls's
  capability builder from `TextDocumentSyncKind.Full` + the registered lifecycle features;
  `loci/saveResult`; pull diagnostics; code-action `command` enrichment; `loci.action.execute`;
  registry-driven `loci/<wire>` + `/preview`; inline handlers on the initialize thread with a
  thread-affinity guard — the SQLite `check_same_thread` trap handled by design, not by
  `check_same_thread=False`).
- `apps/lsp/host.py` — the transport-agnostic `LociHost` (envelope, `snapshot_payload`,
  preview purity, typed error boundary).
- `src/loci_core/protocol/envelope.py` — the shared projection (CLI + LSP).
- `apps/cli/main.py` — refactored onto the envelope module + the **`loci init`** verb.
- `flake.nix` — `packages.<sys>.{loci-core, loci-lsp, default}` + the restored
  `checks.<sys>.loci-lsp-tests` pytest gate (pygls 2.1.1 already in the locked nixpkgs).
- `pyproject.toml` — `[project.scripts]` `loci` + `loci-lsp`, pygls dep, pytest-lsp dev dep.

## What this repo changed to align (all verified)

| Change | Result |
|---|---|
| `flake.lock` bump to `4a8d5e2` | `nix build .#loci-lsp` / `.#loci-nvim` / `.#loci` all green; the built bin carries both `loci` + `loci-lsp` |
| `flake.nix` — restored `checks.<sys>.loci-lsp-tests` re-export | engine pytest gate runs in `nix flake check` |
| `flake.nix` — client check PATH now includes the flake's `loci-lsp` bin | the sandboxed suite exercises the REAL binary (t17) |
| `run-tests.sh` — shim is now **t15-only** (was shadowing PATH for every test); runner prefers the flake's own build when the on-PATH `loci` lacks `init` (stale fleet profile) | local runs don't depend on the (pre-V2) profile binaries |
| **`t17_real_fullstack.lua`** (new) — real attach → `loci init` → `documents/create` → file lands on disk with the canonical `loci:` region → `vim.t.loci_state` set → D-028 refusal as a typed notice | the contract is real, not just faked |
| docs + AGENTS.md + tests README — removed "pending/being restored" language | accurate |

## Verification

- `bash .scratch/tests/run-tests.sh` → **17/17** (16 hermetic + t17 real-engine)
- `nix flake check` → **all checks passed** (both `loci-lsp-tests` and `loci-nvim-tests`,
  t17 green inside the sandbox against the flake's own re-export)

## Note for the fleet

`/etc/profiles/per-user/andrew/bin/{loci,loci-lsp}` are still the **pre-V2** build
(`loci-core-0.2.0`): the runner works around them (and the nix check never touches them), but the
fleet profile should be rebuilt from nix-meta when convenient so interactive Neovim uses the new
host. That is the DAG downstream (`loci-core → loci.nvim → nix-nvim → nix-terminal → nix-meta`).

## Remaining (optional, from 02-PLAN P3)

Link-a-file-to-workspace (`workspaces/put` files list), registry-derived palette (Q5),
`graph/neighbors`/`traversal` views, `documents/move` UI, standalone adoption verb, statusline
staleness segment (`vim.t.loci_state` is populated; nothing consumes it yet).
