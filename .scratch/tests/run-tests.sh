#!/usr/bin/env bash
# run-tests.sh — hermetic headless test suite for the loci.nvim client.
#
# Each test is one `nvim --headless` invocation in a FRESH sandbox (temp dir):
# fixture vaults (repoA on `feature-x`, repoB on `main-b`) are recreated per test,
# so a test can never leak a `.loci` marker dir or session into the next one (the
# attach autocmd would otherwise spawn a second REAL client and pollute results).
# A test passes iff its output contains `RESULT: PASS`; anything else (crash,
# hang past the timeout, failed assertion) fails the run.
#
# Dependencies: nvim (0.12.x), python3, git, timeout. The REAL loci-lsp binary is
# used by exactly one test (t17, F9 end-to-end); every other test runs against the
# Python JSON-RPC fakeservers in ./fakeservers. resession.nvim v1.2.0 is vendored
# under ./vendor/resession (the session tests use the REAL plugin). wayfinder is
# stubbed to the two API functions the client calls (trail_active_name /
# trail_save_named) — see README.md for why.
#
# Usage: ./run-tests.sh [test-name-filter]
#   e.g. ./run-tests.sh t05        # run just the F1 anchoring test
#        ./run-tests.sh f5         # run every test whose name matches "f5"

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NVIM="${NVIM:-/nix/store/10a937czlcj9zg65injb2v7j6w309ndg-neovim-0.12.3/bin/nvim}"
[ -x "$NVIM" ] || { echo "nvim not found at $NVIM (set NVIM)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required on PATH"; exit 1; }
command -v git >/dev/null || { echo "git required on PATH"; exit 1; }
command -v timeout >/dev/null || { echo "timeout required on PATH"; exit 1; }

# the real server for t17 (nix fleet path; also on the profile PATH)
if ! command -v loci-lsp >/dev/null 2>&1; then
  export PATH="$PATH:/etc/profiles/per-user/andrew/bin"
fi

FILTER="${1:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loci-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- fixtures -----------------------------------------------------------------

setup_vault() {
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" config user.email test@loci
  git -C "$dir" config user.name "loci tests"
  printf 'note content\n' >"$dir/note.md"
  printf 'f\n' >"$dir/f.txt"
  git -C "$dir" add -A >/dev/null
  git -C "$dir" commit -qm c1
}

# ---- per-test driver -----------------------------------------------------------

# run_test <name> [VAR=value ...]
run_test() {
  local name="$1"
  shift
  local sandbox="$WORK/$name"
  rm -rf "$sandbox"
  mkdir -p "$sandbox" "$sandbox/sessions" "$sandbox/bin"
  setup_vault "$sandbox/repoA" feature-x
  setup_vault "$sandbox/repoB" main-b
  # cwd stays the sandbox (NOT a git repo): F6's "launch dir is not a repo" premise.

  # a `loci-lsp` shim on PATH lets the REAL attach() autocmd spawn a fake server
  # (t16, F9 hygiene) instead of the real binary (t17).
  cat >"$sandbox/bin/loci-lsp" <<EOF
#!/usr/bin/env bash
exec python3 "$TESTS_DIR/fakeservers/fs_index.py" "\$@"
EOF
  chmod +x "$sandbox/bin/loci-lsp"

  # per-test response files (paths are sandbox-specific, so they are crafted here)
  cat >"$sandbox/resp_first.json" <<EOF
{"editor_state": {"git": {"branch": null, "worktree_path": null}}}
EOF
  cat >"$sandbox/resp_recorded.json" <<EOF
{"editor_state": {"git": {"branch": null, "worktree_path": "$sandbox/repoA"}}}
EOF

  local out
  out="$(cd "$sandbox" && env \
    PATH="$sandbox/bin:$PATH" \
    LOCI_PLUGROOT="$REPO_ROOT" \
    LOCI_TESTS="$TESTS_DIR" \
    LOCI_WORK="$sandbox" \
    LOCI_REPO_A="$sandbox/repoA" \
    LOCI_REPO_B="$sandbox/repoB" \
    LOCI_SESSIONS="$sandbox/sessions" \
    "$@" \
    timeout 180 "$NVIM" --headless -u NONE \
    -c "lua dofile('$TESTS_DIR/common.lua')" \
    -c "lua dofile('$TESTS_DIR/$name.lua')" \
    -c "qa!" 2>&1)"
  local rc=$?

  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "RESULT: PASS"; then
    return 0
  else
    printf '    (rc=%s)\n' "$rc"
    printf '%s\n' "$out" | sed 's/^/    /' | tail -25
    return 1
  fi
}

# ---- suite --------------------------------------------------------------------

# entries: "name", "name|label", or "name|label|VAR=value VAR2=value2"
tests=(
  "t01_module_load"
  "t02_no_client_warn"
  "t03_latency_notice"
  "t04_single_vault"
  "t05_two_vault_anchor"
  "t06_midflow_switch"
  "t07_pinned_checktime"
  "t08_f5_palette_create"
  "t09_f5_startwork_open"
  "t10_activation_tab"
  "t11_activation_global"
  "t12_deactivate_happy"
  "t13_deactivate_wrong_tab"
  "t14_prompt_args|cancel|CASE=A"
  "t14_prompt_args|empty-vocab|CASE=B"
  "t15_f7_unsaved_warning"
  "t16_f9_server_death"
  "t17_f9_real_server"
  "t18_f6_git|first|CASE=first"
  "t18_f6_git|recorded|CASE=recorded"
)

PASS=0
FAIL=0
for entry in "${tests[@]}"; do
  IFS='|' read -r name label envs <<<"$entry"
  envargs=()
  if [ -n "$envs" ]; then
    for e in $envs; do
      envargs+=("$e")
    done
  fi
  if [ -n "$FILTER" ] && ! printf '%s' "$name" | grep -qi "$FILTER"; then
    continue
  fi
  display="$name"
  if [ -n "$label" ] && [ "$label" != "$name" ]; then
    display="$name ($label)"
  fi
  if run_test "$name" "${envargs[@]+"${envargs[@]}"}"; then
    echo "PASS  $display"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $display"
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "loci.nvim headless suite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
