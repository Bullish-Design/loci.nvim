# loci.nvim — repoman-enabled devenv.
#
# RepoMan is always on. This base template wires the two language-agnostic core
# managers: copy (copyroom — templating / convergence) and git (gitman — version
# control). Language add-ons (e.g. template-py) extend repoman.managers with
# their own managers (test, …).
{ ... }:

{
  # Project 039: the store-toolchain opt-out moved to the tracked manifests --
  # `cliProvider = "venv"` in .repoman/project.toml, and `[toolchain] enable =
  # false` in vendomat.toml. Both modules now reach this repository from the
  # system profile, so neither option belongs to an input declared here.

  # Python venv for uv-managed deps. The manager CLIs (copyroom, gitman) come from
  # the SYSTEM-WIDE toolchain venv (`repoman-sync --machine`), not this repo's venv.
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
