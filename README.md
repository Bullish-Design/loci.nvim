# loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

A [repoman](https://github.com/Bullish-Design/repoman)-managed [devenv](https://devenv.sh)
project. RepoMan is always enabled. `.repoman/project.toml` selects the **copy**
(copyroom — templating / convergence) and **git** (gitman — version control) managers.

## Getting started

```bash
devenv shell          # enter the pinned environment
repoman-sync          # install the manager toolchain
repoman managers      # list the wired managers
repoman doctor        # health-check the wiring + each manager
```

## Staying current with the template

This project uses local Templateer sources from `template-nix`. Update its base
layer to a released ref:

```bash
copyroom update --ref <template-ref>
```

Projects with the `module` layer must update that layer too:

```bash
copyroom update --layer module --ref <template-ref>
```

## Author

Bullish Design <BullishDesignEngineering@gmail.com>
