# AGENTS.md — loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

## What this repo is
A `template-nix`-derived repo that **hand-owns its own flake** (no templated
`flake.nix` / `modules/` — e.g. a plugin or package repo). Its devenv files
declare the repo's development settings.

## Conventions (inherited from template-nix — do not break)
- In-repo ops go through the devenv: `devenv shell -- <cmd>`.
- This repository owns its project ID and groups in `.devman/project.toml`
  and its project settings in `devenv.nix`.
- For Devman workflows, use the skills linked under `.agents/skills/`.
- The generated Devman manifest starts with `groups = []`. Add the `base` group
  only after this repository defines both `base:check` and `base:test` task bodies
  in `devenv.nix`. A module flake's `nix flake check` does not define those tasks.

## Inherited vs owned
- **Inherited** (converged by CopyRoom): `devenv.{nix,yaml}`,
  `.gitignore`.
- **Owned** (template seeds, you fill): `.devman/project.toml`,
  project tasks in `devenv.nix`, the whole `flake.nix` / package build,
  docs, optional `scripts/`.

## Validate
`nix flake check`.

## Author
Bullish Design <BullishDesignEngineering@gmail.com>
