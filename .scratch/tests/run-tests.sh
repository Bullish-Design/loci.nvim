#!/usr/bin/env bash
# run-tests.sh — hermetic headless test suite for the loci.nvim client (V2 wire).
#
# Each test is one `nvim --headless` invocation in a FRESH sandbox (temp dir):
# fixture vaults (repoA on `feature-x`, repoB on `main-b`) are recreated per test,
# so a test can never leak a `.loci` marker dir or session into the next one (the
# attach autocmd would otherwise spawn a second REAL client and pollute results).
# A test passes iff its output contains `RESULT: PASS`; anything else (crash,
# hang past the timeout, failed assertion) fails the run.
#
# Dependencies: nvim (0.12.x), python3, git, timeout. Every test runs against the
# Python JSON-RPC fakeserver in ./fakeservers — fs_v2.py is a reference
# implementation of the V2 wire contract (see
# .scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md) so the Lua
# suite pins the CONTRACT the engine host must implement. resession/wayfinder are
# no longer used (activation is gone from V2). t15 exercises the REAL attach()
# path through a `loci-lsp` shim that execs fs_v2.py.
#
# Usage: ./run-tests.sh [test-name-filter]
#   e.g. ./run-tests.sh t05        # run just the workspace-list test
#        ./run-tests.sh t1         # run every test whose name matches "t1"

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

# The real-server tests (t17, t34) must run against the engine THIS FLAKE PINS,
# never against whatever `loci-lsp` the fleet profile happens to carry. Inside the
# nix check that is already true — the checkPhase puts the re-export first on PATH
# — so a local run must reach the same binary or it is measuring a different
# engine and reporting it as this one's result.
#
# This used to test the profile binary for the `init` verb and keep it whenever it
# had one. That heuristic answers "is this binary V2?", not "is this binary the
# pinned rev", so a profile build one engine release behind passed the test and was
# used: t34 then FAILED against a fix that had already landed in the pinned rev.
# Build the flake's own output instead, unconditionally (cached by the store after
# the first run). `NIX_BUILD_TOP` marks the sandbox, where there is no `nix` and no
# network — leave PATH alone there.
if [ -z "${NIX_BUILD_TOP:-}" ] && command -v nix >/dev/null 2>&1; then
  local_loci_bin="$(cd "$REPO_ROOT" && nix build --no-link --print-out-paths .#loci-lsp 2>/dev/null || true)"
  if [ -n "$local_loci_bin" ] && [ -x "$local_loci_bin/bin/loci-lsp" ]; then
    export PATH="$local_loci_bin/bin:$PATH"
    echo "run-tests: using the flake's own loci-lsp/loci ($local_loci_bin)"
  else
    echo "run-tests: WARNING could not build .#loci-lsp; falling back to PATH — t17/t34 may measure a DIFFERENT engine" >&2
  fi
fi

FILTER="${1:-}"
# Belt-and-braces: a timeout'd/aborted nvim never runs finish(), so its detached
# LSP children would otherwise linger (they spin on stdin). Kill anything this
# harness spawned. NOTE: do not run two harness instances concurrently.
cleanup_fakes() {
  pkill -f "$TESTS_DIR/fakeservers/fs_" 2>/dev/null || true
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loci-tests.XXXXXX")"
# Clean up on EVERY exit (Ctrl-C/abort included), not just between tests: a
# suite interrupted mid-test would otherwise orphan its fakeservers.
trap 'rm -rf "$WORK"; cleanup_fakes' EXIT

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

  # A `loci-lsp` shim on PATH lets the REAL attach() autocmd spawn a fake server
  # instead of the real binary — needed ONLY by t15 (server-death hygiene; the
  # shim is a fs_v2.py wrapper that can die on command). Every other test uses
  # spawn_fake explicitly (argv-config'd fs_v2.py) or the REAL binary (t17
  # real-server smoke), so the shim must NOT shadow PATH for them. The shebang
  # must be a RESOLVED interpreter: the generic /usr/bin/env does not exist
  # inside the nix build sandbox (glibc execvp then silently falls through to
  # the real server). fs_v2.py takes its config from FS_* env vars (inherited
  # by the shim).
  if [ "$name" = "t15_server_death" ]; then
    local bash_path
    bash_path="$(command -v bash)"
    cat >"$sandbox/bin/loci-lsp" <<EOF
#!$bash_path
exec python3 "$TESTS_DIR/fakeservers/fs_v2.py"
EOF
    chmod +x "$sandbox/bin/loci-lsp"
  fi

  local out
  out="$(cd "$sandbox" && env \
    PATH="$sandbox/bin:$PATH" \
    FS_LOG="$sandbox/fs.log" \
    FS_RESPONSE="" \
    FS_DIAGNOSTICS="" \
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
  "t04_not_initialized"
  "t05_workspace_list"
  "t06_status_hub"
  "t07_note_create"
  "t08_daily"
  "t09_projects"
  "t10_health"
  "t11_code_action"
  "t12_diag_filter"
  "t13_save_result"
  "t14_archive"
  "t15_server_death"
  "t16_create_workspace"
  "t17_real_fullstack"
  "t18_link_file"
  "t19_neighbors"
  "t20_traversal"
  "t21_move_document"
  "t22_adopt_standalone"
  "t23_palette_registry"
  "t24_unmanaged_toggle"
  "t25_statusline_segment"
  "t26_refusal_envelope"
  "t27_doctor_partial"
  "t28_scale"
  "t29_refused_effect"
  "t30_save_new_file"
  "t31_diag_mapping"
  "t32_tui_interactive"
  "t33_relations_status"
  "t34_real_new_file_save"
  "t35_real_link_empty_workspace"
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
  cleanup_fakes
done

echo
echo "loci.nvim headless suite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
