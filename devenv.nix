# loci.nvim — repoman-enabled devenv.
#
# RepoMan is always on. The tracked .repoman/project.toml selects its manager
# roster. This base project uses copyroom and gitman.
{ ... }:

{
  repoman.enable = true;

  # Devman bootstraps its central declaration on the first shell entry and
  # reconciles the machine-local links and agent pool on the next entry.
  devman = {
    enable = true;
    project = "loci.nvim";
    groups = [ "base" ];
  };

  # A Python venv hosts the manager CLIs (copyroom, gitman) that repoman-sync
  # installs — required even though this project isn't Python.
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
