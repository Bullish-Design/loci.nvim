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

    # loci-lsp is built FROM the loci-core engine repo. Pinned to a pushed rev so the
    # published flake is reproducible + fleet-consumable (nix-meta unifies nixpkgs
    # upward). For local engine dev, override this input against a working checkout:
    #   nix build --override-input loci-core path:../loci-core .#loci-lsp
    # loci-core is PRIVATE, so `github:` 404s on headless boxes (the archive API
    # is token-gated). Use the fleet git+ssh form (like zelligate/nix-secrets) so
    # boxes with an authorized SSH key can fetch it; the lock still pins an exact
    # rev for reproducibility. For local engine dev, override this input:
    #   nix build --override-input loci-core path:../loci-core .#loci-lsp
    loci-core = {
      url = "git+ssh://git@github.com/Bullish-Design/loci-core.git?ref=main";
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
          # Restored with the V2 LSP host (loci-core project 32 / Q1 Option 1a):
          # the pygls transport + console script + flake output are back on the
          # engine's main. The client's wire contract lives in
          # .scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md.
          loci-lsp = loci-core.packages.${system}.loci-lsp;
          # Thin re-export of loci-core's CLI (`loci`) — the out-of-editor arm and
          # the vault bootstrap path (`loci init`). It rides the same DAG hop as
          # loci-lsp so nix-nvim keeps ONE edge to loci-core; without this the
          # binary exists only inside the loci-lsp wrapper's own PATH and never
          # reaches the user's profile.
          loci = loci-core.packages.${system}.loci-core;
          default = self.packages.${system}.loci-nvim;
        });

      # CI gates. The engine-side pytest/pytest-lsp gate lives in loci-core's own
      # flake and is re-exported here (AGENTS.md: the real test gate); the client
      # gate is the hermetic Lua suite, which now ALSO exercises the real
      # `loci-lsp` binary (t17 real-server smoke) against this flake's re-export.
      checks = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          loci-lsp-tests = loci-core.checks.${system}.loci-lsp-tests;

          # Hermetic client suite: Python JSON-RPC fakeservers (fs_v2.py = a
          # reference implementation of the V2 wire contract) + fixture git
          # vaults, one check per scenario — plus t17, which attaches the REAL
          # loci-lsp (this flake's re-export) and runs a full documents/create
          # round trip. Needs nvim >= 0.12 (the flake's nixpkgs provides 0.12.x).
          loci-nvim-tests = pkgs.stdenvNoCC.mkDerivation {
            name = "loci-nvim-tests";
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [
                ./lua
                ./.scratch/tests
              ];
            };
            dontBuild = true;
            doCheck = true;
            nativeBuildInputs = [ pkgs.git pkgs.python3 pkgs.neovim ];
            checkPhase = ''
              export HOME="$PWD/home" && mkdir -p "$HOME"
              export NVIM="$(command -v nvim)"
              export LOCI_PLUGROOT="$PWD"
              export PATH="${self.packages.${system}.loci-lsp}/bin:$PATH"
              bash .scratch/tests/run-tests.sh
            '';
            installPhase = "mkdir -p $out && echo ok > $out/result";
          };
        });
    };
}
