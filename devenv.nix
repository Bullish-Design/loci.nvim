# loci.nvim — devenv.
#
# The host profile puts the managers (copyroom, gitman) on PATH.
{ pkgs, ... }:

{
  # Runtime binaries that the host copyroom and the repo scripts shell out to.
  # copyroom runs `git` and `patch`. scripts/check-local-engine.sh runs `git`.
  packages = [ pkgs.git pkgs.gnupatch ];

  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };

  # The central devman overlay (devenv.local.nix) wires the `base` group.
  # The flake exports real `checks`: `loci-lsp-tests` and `loci-nvim-tests`.
  # `base:check` evaluates every check without a build.
  # `base:test` builds and runs them.
  tasks = {
    "base:check".exec = "nix flake check --no-build";
    "base:test".exec = "nix flake check";
  };
}
