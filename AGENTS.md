# AGENTS.md — loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

## What this repo is
A `template-nix`-derived repo that **hand-owns its own flake** (no templated
`flake.nix` / `modules/` — e.g. a plugin or package repo). The central personal
overlay supplies its development tools.

## Conventions (inherited from template-nix — do not break)
- Personal-use-only: hardcode `andrew`; no portability / multi-user ceremony.
- In-repo ops go through the devenv: `devenv shell -- <cmd>`.
- `nix-meta` supplies the tool versions and RepoMan's devenv module through the
  central overlay. This repository owns its project ID and groups in
  `.devman/project.toml` and its manager roster in `.repoman/project.toml`.
- The generated Devman manifest starts with `groups = []`. Add the `base` group
  only after this repository defines both `base:check` and `base:test` task bodies
  in `devenv.nix`. A module flake's `nix flake check` does not define those tasks.

## Inherited vs owned
- **Inherited** (converged by CopyRoom): `devenv.{nix,yaml}`,
  `.gitignore`.
- **Owned** (template seeds, you fill): `.devman/project.toml`,
  `.repoman/project.toml`, project tasks in `devenv.nix`, the whole `flake.nix` / package build,
  docs, optional `scripts/`.

## Validate
`nix flake check`.

## Author
Bullish Design <BullishDesignEngineering@gmail.com>