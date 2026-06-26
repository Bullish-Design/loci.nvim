# flake.nix — loci.nvim (REPO-OWNED, not template-rendered).
#
# The template-nix Open-Q-4 exception: unlike every other library (which exports a
# static nixosModules/homeManagerModules attrset), loci.nvim exports per-system
# `packages` — the vim-plugin derivation + the loci-lsp server binary — so it needs
# a forAllSystems wrap the plain skeleton lacks. Scaffolded with module_class=none
# (no templated flake/modules); this file is owned outright here.
#
# loci-lsp is an editable path-dep of the loci-core engine and cannot be authored
# here; per D1-a (loci.nvim-PLAN §10), loci-core grows a flake exporting
# packages.<sys>.loci-lsp, and this flake RE-EXPORTS it (+ the plugin output, which
# IS loci.nvim's own). DAG: loci-core → loci.nvim → nix-nvim → nix-terminal → nix-meta.
{
  description = "The loci Neovim plugin (thin loci-lsp client) + the loci-lsp server binary.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # loci-lsp is built FROM the loci-core engine repo (absolute path in dev — a
    # relative path:../loci-core escapes this flake's tree and is rejected in pure
    # eval; the fleet form is github:…?ref=<tag>). nix-meta unifies nixpkgs upward.
    loci-core = {
      url = "path:/home/andrew/Documents/Projects/loci-core";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, loci-core, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          # loci.nvim's OWN output: the plugin derivation (→ nix-nvim rtp).
          loci-nvim = pkgs.callPackage ./nix/loci-nvim.nix { };
          # Thin re-export of loci-core's server binary (→ nix-nvim PATH).
          loci-lsp = loci-core.packages.${system}.loci-lsp;
          default = self.packages.${system}.loci-nvim;
        });

      # CI gate as a flake check: the loci-lsp pytest + pytest-lsp suite, re-exported
      # from loci-core's flake (the engine + pygls + pytest-lsp closure lives there).
      checks = forAllSystems (system: {
        loci-lsp-tests = loci-core.checks.${system}.loci-lsp-tests;
      });
    };
}
