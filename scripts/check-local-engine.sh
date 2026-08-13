#!/usr/bin/env bash
# check-local-engine.sh — run every gate against a LOCAL loci-core checkout.
#
# WHY THIS EXISTS
# `flake.lock` pins loci-core to a pushed rev, so a plain `nix flake check` proves
# the client works against the engine as PUBLISHED. It says nothing about the
# engine as it is being WRITTEN. Engine work sits in the sibling checkout for days
# before it is pushed, and a wire change made there reaches this repo only after it
# is already downstream. This script closes that window: it points the flake input
# at the local tree — UNCOMMITTED work included — and runs three gates:
#
#   1. loci-lsp-tests   the engine's own pytest/pytest-lsp suite (re-exported here)
#   2. loci-nvim-tests  the hermetic Lua suite + t17, which attaches the REAL
#                       loci-lsp built from that local tree
#   3. wire drift       re-capture the effect contract from the live local server
#                       and diff it against the tracked fixtures.json
#
# Gate 3 is the one a passing suite cannot give you. `fs_v2.py` validates itself
# against `fixtures.json`, so the fake stays self-consistent while the engine moves
# underneath it. Only a re-capture can tell you the ground truth changed.
#
# WHAT GATE 3 DOES NOT COVER without `--vault`. The effect capture rewrites only the
# EFFECT half of the contract: the mutating wires' key sets, `commit_status`,
# `save_result_*`, `code_action_*` and `action_execute_*`. The read half —
# `document_keys`, `workspace_view_keys`, `revision_length`, `id_pattern` and every
# read wire — comes from `capture-fixtures.sh`, which needs a real vault. So a
# clean run without `--vault` means "no EFFECT drift", not "no drift". Pass a vault
# when the engine has touched a read path.
#
# `git+file:` — not `path:` — is deliberate. `path:` copies the directory verbatim,
# and loci-core carries ~1 GB of gitignored `.devenv`/`.venv`. The git fetcher
# honours .gitignore and still picks up a dirty tree (nix says so: "Git tree ... is
# dirty"). If that warning is absent, the run did NOT see your uncommitted work.
#
# Usage:
#   scripts/check-local-engine.sh                     # engine at ../loci-core
#   scripts/check-local-engine.sh --engine <path>
#   scripts/check-local-engine.sh --vault <root>      # ALSO re-capture read fixtures
#   scripts/check-local-engine.sh --skip-flake-check  # drift gate only (fast)
#
# --vault is opt-in because the read capture needs a real vault and WRITES to
# nothing, while the effect capture builds its own throwaway vault every run.
#
# READ THE READ-HALF DIFF CAREFULLY. Its `enums` lists (`kind`, `status`, `state`,
# `identity_state`) are derived from the VALUES PRESENT IN THE VAULT YOU PASS, not
# from anything the engine declares. Point it at a different vault and those lists
# change with no engine change at all — measured 2026-08-13 against a generated
# representative vault (loci-core `tools/build_representative_vault.py`), which
# added `reference`/`idea`/`meeting` kinds and `done`/`archived`/`planned` statuses
# purely because it contains notes the previous capture's vault did not. A WIDER
# list is corpus variance; treat only a NARROWER list, or a changed key set, as
# drift. Use the same vault as the tracked capture when you want a clean diff.
#
# Exit: 0 clean, 1 a gate failed or the wire drifted, 3 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKESERVERS="$HERE/.scratch/tests/fakeservers"
ENGINE="$HERE/../loci-core"
VAULT=""
RUN_FLAKE_CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:-}"; shift 2 || exit 3 ;;
    --vault) VAULT="${2:-}"; shift 2 || exit 3 ;;
    --skip-flake-check) RUN_FLAKE_CHECK=0; shift ;;
    -h|--help) sed -n '2,37p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 3 ;;
  esac
done

if [ ! -f "$ENGINE/flake.nix" ]; then
  echo "error: no flake.nix at $ENGINE — pass --engine <path to loci-core>" >&2
  exit 3
fi
ENGINE="$(cd "$ENGINE" && pwd)"
OVERRIDE=(--override-input loci-core "git+file://$ENGINE")

echo "engine:  $ENGINE"
if git -C "$ENGINE" diff --quiet HEAD 2>/dev/null; then
  echo "tree:    clean @ $(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null)"
else
  echo "tree:    DIRTY @ $(git -C "$ENGINE" rev-parse --short HEAD 2>/dev/null) (uncommitted work is included)"
fi
echo

FAILED=()

# ---- gates 1 + 2: both suites, against the local engine -----------------------
if [ "$RUN_FLAKE_CHECK" -eq 1 ]; then
  echo "== nix flake check (loci-lsp-tests + loci-nvim-tests) =="
  nix flake check "${OVERRIDE[@]}" -L 2>&1 | tee /tmp/loci-local-engine-check.log \
    | grep -E "^(warning: Git tree|error|.*> (PASS|FAIL)|all checks passed)"
  if ! grep -q "all checks passed" /tmp/loci-local-engine-check.log; then
    FAILED+=("nix flake check — see /tmp/loci-local-engine-check.log")
  fi
  echo
fi

# ---- gate 3: wire-contract drift ---------------------------------------------
# Build the local engine's binaries, then re-capture into a COPY of the fakeserver
# directory. The capture scripts write to `fixtures.json` beside themselves, so the
# copy keeps the tracked file untouched and the diff is the whole answer.
echo "== wire-contract drift (live local loci-lsp vs tracked fixtures.json) =="
BIN_LSP="$(nix build "$HERE#loci-lsp" "${OVERRIDE[@]}" --no-link --print-out-paths 2>/dev/null)"
BIN_CLI="$(nix build "$HERE#loci" "${OVERRIDE[@]}" --no-link --print-out-paths 2>/dev/null)"
if [ -z "$BIN_LSP" ] || [ -z "$BIN_CLI" ]; then
  echo "error: could not build loci-lsp / loci from $ENGINE" >&2
  exit 1
fi

TMP="$(mktemp -d -t loci-drift-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cp -r "$FAKESERVERS" "$TMP/fakeservers"
rm -rf "$TMP/fakeservers/__pycache__"

export PATH="$BIN_LSP/bin:$BIN_CLI/bin:$PATH"

if ! python3 "$TMP/fakeservers/capture-effects.py" --write-contract > "$TMP/effects.txt" 2> "$TMP/effects.err"; then
  echo "error: the effect capture failed — the engine may have moved under the capture itself:" >&2
  tail -20 "$TMP/effects.err" >&2
  FAILED+=("capture-effects.py")
fi

if [ -n "$VAULT" ]; then
  if [ ! -f "$VAULT/.loci/vault.toml" ]; then
    echo "error: --vault $VAULT has no .loci/vault.toml" >&2
    exit 3
  fi
  if ! "$TMP/fakeservers/capture-fixtures.sh" "$VAULT" --write-contract > "$TMP/reads.txt" 2> "$TMP/reads.err"; then
    echo "error: the read capture failed:" >&2
    tail -20 "$TMP/reads.err" >&2
    FAILED+=("capture-fixtures.sh")
  fi
fi

if diff -u "$FAKESERVERS/fixtures.json" "$TMP/fakeservers/fixtures.json" > "$TMP/drift.diff"; then
  echo "no drift — the fake still describes the engine."
else
  echo "DRIFT: the engine's wire no longer matches fixtures.json."
  echo
  cat "$TMP/drift.diff"
  echo
  echo "To adopt the engine's new shape, re-capture in place:"
  echo "  nix shell $HERE#loci-lsp $HERE#loci ${OVERRIDE[*]} \\"
  echo "    --command $FAKESERVERS/capture-effects.py --write-contract"
  echo "Then fix every fake handler and client site the diff implicates. A fixture"
  echo "adopted without that pass is a lie the whole suite will then agree with."
  FAILED+=("wire-contract drift")
fi
echo

# ---- verdict ------------------------------------------------------------------
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "OK — the client holds against $ENGINE"
  exit 0
fi
echo "FAILED:"
for f in "${FAILED[@]}"; do echo "  - $f"; done
exit 1
