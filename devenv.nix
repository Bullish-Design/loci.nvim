# loci.nvim — devenv.
#
# The host profile puts the managers (copyroom, gitman) on PATH.
{ pkgs, ... }:

{
  # Devman bootstraps its central declaration on the first shell entry and
  # reconciles the machine-local links and agent pool on the next entry.
  devman = {
    enable = true;
    project = "loci.nvim";
    groups = [ "base" ];
  };

  # Runtime binaries that the host copyroom and the repo scripts shell out to.
  # copyroom runs `git` and `patch`. scripts/check-local-engine.sh runs `git`.
  packages = [ pkgs.git pkgs.gnupatch ];

  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };

  # devman — the automation plane (CONCEPT.md §5). `base` alone, and this is the
  # repository wave 2 exists to prove: a Neovim plugin, written in Lua, whose
  # tests are Nix derivations. It takes the same two names as every Python
  # repository on the plane and needs no group of its own — which is §16's
  # "there are no ecosystem groups", measured rather than argued.
  # base's two names. The flake exports real `checks` — `loci-lsp-tests` and
  # `loci-nvim-tests` — so the two rungs are genuinely different work here:
  # `--no-build` evaluates every check without realising one, and dropping the
  # flag runs them.
  tasks = {
    "base:check".exec = "nix flake check --no-build";
    "base:test".exec = "nix flake check";
  };
}
