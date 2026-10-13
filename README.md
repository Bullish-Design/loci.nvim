# loci.nvim

The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.

A [devenv](https://devenv.sh) project. The host profile provides **copyroom**
(template convergence) and **gitman** (workspaces).

## Getting started

```bash
devenv shell          # enter the pinned environment
copyroom status       # show how the project differs from its template
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
