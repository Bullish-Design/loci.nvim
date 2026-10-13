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

  # Install pyjutsu (gitman's native dep) from vendomat's prebuilt wheelhouse instead
  # of compiling its maturin/Rust extension — this repo ships no Rust toolchain. The
  # vendomat module (imported in devenv.yaml) exports UV_FIND_LINKS; the `wheel:pyjutsu`
  # source in repoman.lock resolves against it. `libs` defaults to [ "pyjutsu" ].
  vendor.enable = true;

  # A Python venv hosts the manager CLIs (copyroom, gitman) that repoman-sync
  # installs from repoman.lock — required even though this project isn't Python.
  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };
}
