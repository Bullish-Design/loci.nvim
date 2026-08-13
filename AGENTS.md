# AGENTS.md — loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

## What this repo is
A `template-nix`-derived repo that **hand-owns its own flake** (no templated
`flake.nix` / `modules/` — `module_class = none`). Only the devenv/repoman skeleton
is template-converged here. It is the **source of the editor DAG**:
`loci-core → loci.nvim → nix-nvim → nix-terminal → nix-meta`.

It exports per-system **`packages`**, not option-modules:
- `packages.<sys>.loci-nvim` — the plugin derivation (`vimUtils.buildVimPlugin` over
  `lua/`); nix-nvim drops it on the runtimepath where `require("loci")` self-initializes.
- `packages.<sys>.loci-lsp` — a **thin re-export** of `loci-core`'s `loci-lsp` (B1/D1-a);
  nix-nvim puts it on PATH so `vim.lsp.start{cmd={"loci-lsp"}}` works.
- `checks.<sys>.loci-lsp-tests` — re-exports loci-core's pytest + pytest-lsp gate.

## The clean-room shape (read before editing the plugin)
- `lua/loci/init.lua` is **ONE file** — a thin LSP *client* written against the
  `loci-lsp` wire protocol. The legacy monolith is GONE: **no** `commands/hooks → service
  → store → result` tree, **no** `result.lua`, **no** `nio.uv` store layer, **no**
  `mini.test` suite (`run_loci_tests.sh` does not exist). The editor holds NO loci logic —
  every semantic decision is server-side in `loci_core.control.*`.
- The `loci-lsp` server is an editable path-dep of the **loci-core** engine and is NOT
  authored here — loci.nvim only *re-exports* loci-core's built binary. The engine + the
  pygls server + their dev shell stay in loci-core.
- **tasknotes is NOT a loci concern** — it lives in nix-nvim's `productivity/` config, not
  here. The loci leader maps live in nix-nvim's `keymaps/leader.lua`; loci ships only the
  `:Loci*` user-commands they call.
- The real test gate is loci-core's pytest/pytest-lsp suite (engine-side, re-exported as this
  flake's `checks.<sys>.loci-lsp-tests`). This repo's flake check `loci-nvim-tests` runs the
  hermetic Lua suite (`.scratch/tests/run-tests.sh`) against `fakeservers/fs_v2.py` — a
  reference implementation of the V2 wire contract — plus t17, which attaches the REAL
  `loci-lsp` (this flake's re-export of the engine's pygls host) for a full `documents/create`
  round trip.

## Conventions (inherited from template-nix — do not break)
- Personal-use-only: hardcode `andrew`; no portability / multi-user ceremony.
- In-repo ops go through the devenv: `devenv shell -- <cmd>`.

## Inherited vs owned
- **Inherited** (converged by `copyroom update`, do NOT hand-edit): `devenv.{nix,yaml}`,
  `repoman.lock`, `copyroom.project.yml`, `.copier-answers.yml`, `.gitignore`.
- **Owned** (template seeds, you fill): the whole `flake.nix` / package build, docs, optional `scripts/`.

## Validate
`nix flake check` — the client against the engine as **published** (`flake.lock` pins a
pushed `loci-core` rev).

`scripts/check-local-engine.sh` — the client against the engine as **written**: it points
the `loci-core` input at the sibling checkout (`../loci-core`, uncommitted work included),
runs both suites, then re-captures the effect contract from the live local `loci-lsp` and
diffs it against `fakeservers/fixtures.json`. Run it whenever loci-core changes; a passing
suite cannot see wire drift, because `fs_v2.py` validates itself against those same
fixtures. Add `--vault <root>` to cover the read half of the contract too.

## Author
Bullish Design <BullishDesignEngineering@gmail.com>
