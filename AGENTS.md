# AGENTS.md — loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

## What this repo is
A `template-nix`-derived repo that **hand-owns its own flake** (no templated
`flake.nix` / `modules/` — e.g. a plugin or package repo). Only the devenv/repoman
skeleton is template-converged here.

## Conventions (inherited from template-nix — do not break)
- Personal-use-only: hardcode `andrew`; no portability / multi-user ceremony.
- In-repo ops go through the devenv: `devenv shell -- <cmd>`.
- The host profile puts the managers (`copyroom`, `gitman`) on `PATH`, and RepoMan
  runs them by name. There is no per-repo `repoman.lock`.

## Inherited vs owned
- **Inherited** (converged by CopyRoom): `devenv.{nix,yaml}`,
  `.gitignore`.
- **Owned** (template seeds, you fill): the whole `flake.nix` / package build, docs, optional `scripts/`.

## Validate
`nix flake check`.

## Author
Bullish Design <BullishDesignEngineering@gmail.com>
