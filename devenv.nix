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
  # installs from repoman.lock — required even though this project isn't Python.
  languages.python = {
    enable = true;
    venv.enable = true;
    uv.enable = true;
  };
}
