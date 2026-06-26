# nix/loci-nvim.nix — the loci plugin as a Neovim plugin derivation.
# Pure-lua, single file (lua/loci/init.lua); no build step. nix-nvim drops the
# result onto the runtimepath, where `require("loci")` self-initializes.
{ vimUtils, lib }:
vimUtils.buildVimPlugin {
  pname = "loci-nvim";
  version = "0-unstable-2026-06-25"; # plugin is versionless; date-stamped
  src = ../.; # the lua/ tree (+ after/ if any)
  # No build/check here: the lua client has no standalone test; the real gate is
  # the loci-lsp pytest/pytest-lsp suite (loci.nvim flake `checks`, from loci-core).
  meta = {
    description = "loci — thin LSP client for Neovim (speaks the loci-lsp protocol)";
    license = lib.licenses.mit;
  };
}
