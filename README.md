# loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

A [repoman](https://github.com/Bullish-Design/repoman)-managed [devenv](https://devenv.sh)
project. RepoMan is always enabled; this repo wires the core managers **copy**
(copyroom — templating / convergence) and **git** (gitman — version control).

## Getting started

```bash
devenv shell          # enter the pinned environment
repoman-sync          # install the manager toolchain from repoman.lock
repoman managers      # list the wired managers
repoman doctor        # health-check the wiring + each manager
```

## Staying current with the template

This project was generated from `template-nix`. Pull template updates with:

```bash
copyroom update          # three-way merge from the latest template tag
```

## Author

Bullish Design <BullishDesignEngineering@gmail.com>
