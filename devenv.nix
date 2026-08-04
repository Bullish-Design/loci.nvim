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

  # Python venv for uv-managed deps. The manager CLIs (copyroom, gitman) come from
  # the SYSTEM-WIDE toolchain venv (`repoman-sync --machine`), not this repo's venv.
  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };
}
