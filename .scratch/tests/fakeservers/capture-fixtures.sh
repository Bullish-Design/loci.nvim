#!/usr/bin/env bash
# capture-fixtures.sh — dump REAL engine responses so fs_v2.py's fixtures can be
# checked (or refreshed) against ground truth instead of hand-authored.
#
# The fixtures in fs_v2.py are deliberately SMALL — tests assert on known paths
# like `notes/a.md`, so we do not paste vault data in wholesale. What must match
# the engine is the shape, width, and vocabulary of every value (see README,
# "Fixture fidelity"). This script prints the engine's actual envelope for each
# wire so a drift is visible in a diff.
#
# Usage:
#   ./capture-fixtures.sh <vault-root> [output-file]
#
# Requires the real `loci` CLI on PATH (nix: `nix shell .#loci`). The CLI and the
# LSP host share LociHost, so the CLI envelope IS the wire envelope.
set -euo pipefail

VAULT="${1:-}"
OUT="${2:-/dev/stdout}"

if [ -z "$VAULT" ] || [ ! -f "$VAULT/.loci/vault.toml" ]; then
  echo "usage: $0 <vault-root> [output-file]   (vault must have .loci/vault.toml)" >&2
  exit 3
fi
if ! command -v loci >/dev/null 2>&1; then
  echo "error: \`loci\` is not on PATH — try: nix shell .#loci" >&2
  exit 2
fi

# wire|extra args — every read the client actually issues
wires=(
  "workspaces/list|"
  "documents/list|state=managed"
  "search/text|query=project"
  "graph/backlinks|ref=notes/Note 1.md"
  "graph/neighbors|ref=notes/Note 1.md"
  "graph/traversal|ref=notes/Note 1.md"
  "graph/project_members|ref=notes/Note 1.md"
  "graph/orphans|"
  "graph/broken_links|"
  "graph/missing_attachments|"
  "graph/ambiguous_links|"
  "maintenance/refresh|"
)

{
  echo "# fs_v2 fixture ground truth"
  echo "# vault: $VAULT"
  echo "# Compare shape/width/vocabulary against fs_v2.DEFAULTS — NOT row-for-row."
  echo
  for entry in "${wires[@]}"; do
    IFS='|' read -r wire args <<<"$entry"
    echo "### $wire"
    # shellcheck disable=SC2086
    if [ -n "$args" ]; then
      loci --vault "$VAULT" --json "$wire" "$args" 2>&1 | head -c 2000
    else
      loci --vault "$VAULT" --json "$wire" 2>&1 | head -c 2000
    fi
    echo
    echo
  done
} >"$OUT"

echo "captured $(printf '%s' "${#wires[@]}") wires -> $OUT" >&2
