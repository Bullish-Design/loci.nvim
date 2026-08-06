# Kickoff prompt — implement the remaining V2 capabilities in loci.nvim

Paste the block below (everything in the fenced section) into a fresh session started
in `/home/andrew/Documents/Projects/loci.nvim`. It is self-contained: it tells the agent
exactly what to read, what to build, in what order, and how to prove it works.

---

```
You are implementing the remaining V2 capabilities in the loci.nvim repository
(current working directory: /home/andrew/Documents/Projects/loci.nvim).

## Context

loci.nvim is a thin Neovim LSP *client* for the external loci-core engine (spoken over
the `loci-lsp` server binary). The repo also re-exports the server and the engine's test
gate via its flake. A multi-phase realignment (project 002) already landed: the client
speaks the V2 wire contract, 17 hermetic tests pass, and `nix flake check` is green
(lock pinned to loci-core @ 4a8d5e2). A detailed implementation guide was just written
for the remaining work — your job is to implement it.

## Read first (in this order)

1. `AGENTS.md` — the clean-room shape and conventions. Non-negotiable:
   - `lua/loci/init.lua` is ONE thin client file. NO loci logic client-side — every
     semantic decision lives in loci-core. All writes go through feature methods
     (`loci/<wire>`) or `loci.action.execute`, then `:checktime`.
   - Mutating features are PREVIEW-THEN-APPLY (the declared pure `/preview` route,
     D-032). Never author a diff client-side, never apply blindly.
   - The engine is the SOLE writer of vault files. Host state stays in the host
     (`vim.t.loci_workspace_id`, `vim.t.loci_state`).
   - Wire truth = `.scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md`;
     the executable reference = `.scratch/tests/fakeservers/fs_v2.py`.
   - In-repo ops go through `devenv shell -- <cmd>`.
2. `.scratch/projects/003-loci-v2-remaining-capabilities/IMPLEMENTATION-GUIDE.md` —
   THE plan. Follow its phases exactly. It contains code sketches; adapt them to the
   file's actual style (check the existing `M.backlinks`/`M.status`/`M.workspaces`
   implementations) and fix any sketch bugs you notice (there is one flagged in
   Phase 4).
3. `.scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md` — the wire
   contract (result shapes, envelope, preview routes).
4. `.scratch/tests/README.md` + `.scratch/tests/common.lua` + `.scratch/tests/run-tests.sh`
   — the test harness. Every test is one `nvim --headless` invocation in a fresh sandbox
   against the fakeserver; pass = output contains `RESULT: PASS`.
5. `.scratch/projects/002-loci-core-v2-realignment/05-STATUS.md` — the "Remaining"
   list at the bottom is the scope statement you are closing.

## Scope (all of these)

A. Standalone adoption verb (`documents/adopt` + preview) — `:LociAdopt`
B. `documents/move` UI (prompt destination, preview shows the `move` line, apply, open
   the moved file) — `:LociMove`
C. `graph/neighbors` per-note picker — `:LociNeighbors`
D. `graph/traversal` per-note picker (rows carry depth) — `:LociTraversal`
E. Link-a-file-to-workspace via `workspaces/put` `files` list, read-modify-write from
   `workspaces/get`, role picker (implementation/reference/related/documentation/test),
   status-hub row — `:LociLinkFile`
F. Q3 escape hatch: `vim.g.loci_show_unmanaged` (default false) honored by the
   diagnostic filter + `:LociToggleUnmanaged`
G. Registry-mirrored palette (Q5): extend `M.palette` with the new verbs; curated
   table; do NOT build a generic 24-feature prompt engine in this pass
H. Statusline staleness segment `M.statusline()`: `""` | `<rev>` | `<rev>!` (the `!`
   when `consistency ~= "current"`), plus the doc contract. nix-nvim wiring is
   downstream — list it in the close-out, do not edit nix-nvim.
Optional: `graph/project_members` view (same shape as C/D) if its result shape is
confirmed against loci-core.

## Decisions to confirm with loci-core FIRST (do this before writing client code)

A sibling checkout of the engine exists at `/home/andrew/Documents/Projects/loci-core`
at the exact pinned rev (4a8d5e2). Confirm against it:

1. `workspaces/put` merge-vs-replace semantics for `files`/`documents`
   (`src/loci_core/features/workspaces.py`). Default flow: read `workspaces/get` view,
   append, PUT full list (correct under either semantics). If it merges, simplify.
2. `graph/neighbors` result shape (NOT in the contract's result-shape table) — confirm
   the CLI projection in `src/loci_core/protocol/registry.py` /
   `apps/cli/main.py`. Update `04-WIRE-CONTRACT.md`'s table in the same commit.
3. `documents/move` request fields (likely `{ref, destination}`) and committed result
   shape (if it carries `.document` like `create`, reuse `open_new_document` after
   apply). `src/loci_core/protocol/registry.py`.
4. `graph/traversal` params (likely `{ref, max_depth?}`).
5. `documents/adopt` params (likely `{ref}`).
6. Note in docs that a true registry-INTROSPECTED palette would need a loci-core wire
   method (e.g. `loci/registry`) — out of scope; the curated client table is the
   surface for now.

If any confirmed shape differs from the guide's assumption, adjust the fakeserver +
tests to the REAL shape (the tests must pin the contract, not the guide's guess), and
note the delta in your final summary.

## Implementation order (one phase at a time; keep the suite green after each)

1. Baseline verify: `devenv shell -- bash .scratch/tests/run-tests.sh` (17/17) and
   `devenv shell -- nix flake check`. Work from a clean tree.
2. Confirm the decisions above against `../loci-core`.
3. Phase 1 — extend `fakeservers/fs_v2.py` (defaults for
   `graph/neighbors`, `graph/traversal`, `documents/adopt`, `documents/move` +
   `/preview`; make `workspaces/put` echo `files`/`documents` params). Suite stays 17/17.
4. Phase 2 — `M.adopt()` + `:LociAdopt`.
5. Phase 3 — `M.move_document()` + `:LociMove`.
6. Phase 4 — `M.neighbors()` / `M.traversal()` via a shared helper + `:LociNeighbors`
   / `:LociTraversal` (+ `M.project_members` if confirmed).
7. Phase 5 — `M.link_file()` + `:LociLinkFile` + status-hub row.
8. Phase 6 — `vim.g.loci_show_unmanaged` + `:LociToggleUnmanaged` (t12 must keep
   passing).
9. Phase 7 — palette entries for all new verbs.
10. Phase 8 — `M.statusline()` + doc contract.
11. Phase 9 — tests t18–t25 (see guide's table), appended to `run-tests.sh`'s `tests=`
    array. Model each on `t16_create_workspace.lua`. t25 uses `FS_RESPONSE` to override
    `_consistency: "indexed"` for the `!` case.
12. Phase 10 — docs: `docs/README.md` (commands table + "entire command surface" line),
    `docs/state-ownership.md` (statusline segment contract + `show_unmanaged`),
    `docs/workspace-lifecycle.md` (link-a-file flow + roles),
    `docs/troubleshooting.md` (move refusal / already-linked rows), and backfill
    `04-WIRE-CONTRACT.md` with the confirmed result shapes.
13. Phase 11 — close-out: update `002/05-STATUS.md`'s "Remaining" section to point at
    003 (done); list the nix-nvim downstream items; final gate; single commit.

## Gate (all must pass before you stop)

- `devenv shell -- bash .scratch/tests/run-tests.sh` → 25/25 (t18–t25 present and green)
- `devenv shell -- nix flake check` → both checks green (loci-lsp-tests + loci-nvim-tests)
- No `loci/op`, `workspace/executeCommand`-as-generic-effect, or `.loci/content` strings
  introduced; no client-side logic that belongs in the engine.
- `git status` clean after your single commit; commit message summarizes the 8 items.

## Communication expectations

- Read the guide fully before touching code. If you find it conflicts with the real
  engine (confirmed against `../loci-core`), the ENGINE wins — adjust and say so.
- Report progress per phase, not once at the end.
- If a gate fails, debug and fix it — do not relax the gate.
- Keep `lua/loci/init.lua` a single file and keep its comment-header conventions
  (each section annotated with arch/wire citations like the existing code).
```

---

## Notes for the author

- The prompt pins the decision points to a real engine checkout (`../loci-core` @
  `4a8d5e2`), so a fresh session can verify shapes instead of trusting the guide's
  assumptions.
- It hard-codes the current working directory; if you ever run it from elsewhere,
  fix the path in the first and the "Decisions" sections.
- It deliberately instructs the agent to keep the suite green after every phase — that
  catches regressions early and makes each phase independently reviewable.
