# loci.nvim — repoman-enabled devenv.
#
# RepoMan is always on. This base template wires the two language-agnostic core
# managers: copy (copyroom — templating / convergence) and git (gitman — version
# control). Language add-ons (e.g. template-py) extend repoman.managers with
# their own managers (test, …).
{ ... }:

{
  repoman.enable = true;
  repoman.managers = [ "copy" "git" ];

  # A Python venv hosts the manager CLIs (copyroom, gitman) that repoman-sync
  # installs from repoman.lock — required even though this project isn't Python.
  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };
}
