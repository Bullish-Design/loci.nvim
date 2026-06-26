# nix/loci-nvim.nix — the loci plugin as a Neovim plugin derivation.
# Pure-lua, single file (lua/loci/init.lua); no build step. nix-nvim drops the
# result onto the runtimepath, where `require("loci")` self-initializes.
{ vimUtils, lib }:
vimUtils.buildVimPlugin {
  pname = "loci-nvim";
  version = "0-unstable-2026-06-25"; # plugin is versionless; date-stamped
  # Filter src to the plugin-relevant tree only (just lua/ here). `src = ../.`
  # would capture .devenv/.git/.jj — and .devenv's dangling GC symlinks trip
  # buildVimPlugin's noBrokenSymlinks check. Filtering is what the plan (§3.1)
  # intended ("filter to lua/ + after/ if any"); only lua/ exists.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../lua;
  };
  # No build/check here: the lua client has no standalone test; the real gate is
  # the loci-lsp pytest/pytest-lsp suite (loci.nvim flake `checks`, from loci-core).
  meta = {
    description = "loci — thin LSP client for Neovim (speaks the loci-lsp protocol)";
    license = lib.licenses.mit;
  };
}
