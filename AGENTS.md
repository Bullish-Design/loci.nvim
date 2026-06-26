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
- The real test gate is loci-core's **pytest/pytest-lsp** suite (re-exported as the flake
  check), not a lua harness.

## Conventions (inherited from template-nix — do not break)
- Personal-use-only: hardcode `andrew`; no portability / multi-user ceremony.
- In-repo ops go through the devenv: `devenv shell -- <cmd>`.

## Inherited vs owned
- **Inherited** (converged by `copyroom update`, do NOT hand-edit): `devenv.{nix,yaml}`,
  `repoman.lock`, `copyroom.project.yml`, `.copier-answers.yml`, `.gitignore`.
- **Owned** (template seeds, you fill): the whole `flake.nix` / package build, docs, optional `scripts/`.

## Validate
`nix flake check`.

## Author
Bullish Design <BullishDesignEngineering@gmail.com>
