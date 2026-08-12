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
#   ./capture-fixtures.sh <vault-root> [output-file]     # dump envelopes for eyeballing
#   ./capture-fixtures.sh <vault-root> --write-contract  # regenerate fixtures.json
#
# `--write-contract` derives the machine-checkable contract (key sets, row arities,
# enum vocabularies, revision width) from what the engine actually returned and
# rewrites fixtures.json, which fs_v2.py validates its DEFAULTS against at startup.
# Run it after an engine change: a drift then fails every scenario immediately
# instead of silently licensing a fixture that lies.
#
# Requires the real `loci` CLI on PATH (nix: `nix shell .#loci`).
#
# SCOPE: READS ONLY. For read features the CLI envelope is the wire envelope, but
# for EFFECTS it is not — the CLI projects a CommandPreview (`{refusals, changes,
# _committed}`) whereas the LSP host sends the SourceCommit (`{commit: {status,
# detail, path}, document}`). Capturing an effect here would produce a fixture the
# client never actually sees; that mistake cost two live bugs (004 F-14/F-15).
# Probe the running loci-lsp for effect shapes instead.
set -euo pipefail

VAULT="${1:-}"
OUT="${2:-/dev/stdout}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [ "$OUT" = "--write-contract" ]; then
  raw="$(mktemp)"
  trap 'rm -f "$raw"' EXIT
  for entry in "${wires[@]}"; do
    IFS='|' read -r wire args <<<"$entry"
    if [ -n "$args" ]; then
      printf '%s\t%s\n' "$wire" "$(loci --vault "$VAULT" --json "$wire" "$args")" >>"$raw"
    else
      printf '%s\t%s\n' "$wire" "$(loci --vault "$VAULT" --json "$wire")" >>"$raw"
    fi
  done
  CONTRACT="$HERE/fixtures.json" python3 - "$raw" <<'PY'
import json, os, sys

# Merge observed structure into the existing contract: the engine is authoritative
# for shapes/widths/vocabularies, but the prose _comment and any wire the capture
# did not exercise are preserved rather than silently dropped.
path = os.environ["CONTRACT"]
with open(path) as fh:
    contract = json.load(fh)

enums = {k: list(v) for k, v in contract["enums"].items()}
wires = dict(contract["wires"])

for line in open(sys.argv[1]):
    wire, _, payload = line.partition("\t")
    env = json.loads(payload)
    if not env.get("ok"):
        continue
    value = {k: v for k, v in env["value"].items() if not k.startswith("_")}
    spec = dict(wires.get("loci/" + wire, {}))
    spec["keys"] = sorted(value)
    for key, rows in value.items():
        if not isinstance(rows, list) or not rows:
            continue
        first = rows[0]
        if isinstance(first, list):
            spec.setdefault("row_arity", {})[key] = len(first)
        elif isinstance(first, str):
            spec.setdefault("row_scalar", [])
            if key not in spec["row_scalar"]:
                spec["row_scalar"].append(key)
        elif isinstance(first, dict):
            for field in ("identity_state", "kind", "status", "state"):
                for row in rows:
                    v = row.get(field)
                    if field in enums and v not in enums[field]:
                        enums[field].append(v)
    if "revision" in value and isinstance(value["revision"], str):
        contract["revision_length"] = len(value["revision"])
    wires["loci/" + wire] = spec

contract["enums"] = enums
contract["wires"] = wires
with open(path, "w") as fh:
    json.dump(contract, fh, indent=2)
    fh.write("\n")
print(f"contract updated: {path}", file=sys.stderr)
PY
  exit 0
fi

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
