# 03 — Open questions (author decisions required)

Each question: the fork, what the record says, and a recommendation. Q1 is the gate.

---

## Q1 — Who owns the LSP server now? (the central decision)

**Fork:** loci-core regrows the transport host (pygls vs dependency-free), loci.nvim vendors one,
or the plugin drops LSP and drives the CLI.

**What the record says:**
- The adapter's docstring: "A pygls host wraps these handlers in its own transport"
  (`apps/lsp/adapter.py:1-9`). The adapter is a deliberate V2 artifact that survived the
  clean-room; only its host is missing.
- Arch §13 assumes an LSP host with overlays, pushed diagnostics, and code actions.
- Guide Phase 13 (LSP/overlays) and Phase 14 (CLI/protocol) are written for a host.
- pygls is **not** in arch §18's deletion list (the deletions are semantic capabilities, not the
  transport).
- The old flake's pygls pin (2.1.1) is proven in nixpkgs (pre-V2 flake overrode it).

**Recommendation: Option 1a — loci-core regrows `apps/lsp` with a pygls host** (flake
`packages.<sys>.loci-lsp` + `[project.scripts]` restored), because it completes the declared
design, keeps the DAG at one edge, and preserves diagnostics/code-actions/overlays — the actual
point of V2's LSP story. **Option 1b** (dependency-free stdio loop — the fakeservers' proven
shape) is the fallback if loci-core refuses the pygls dep; same wire contract. Option 2 (vendor
in loci.nvim) breaks the pure-Lua plugin derivation and the D1-a ownership; Option 3 (CLI only)
throws away the adapter. **This is not settleable from the record alone — the prompt says to
pick it explicitly, and it gates everything (P0.1).**

**Notable sub-question:** does the host expose the 24 features as `loci/<wire>` methods (e.g.
`loci/documents/list`, `loci/workspaces/put`) with the CLI-style envelope, plus the adapter's
LSP methods? The plugin's whole read/effect layer depends on that shape. Recommend: yes — the
registry (`protocol/registry.py`) already defines wire names and request models; the host should
be registry-driven, exactly like the CLI.

---

## Q2 — Vault bootstrap: who calls `initialize_vault`?

**Fork:** the engine regrows an init command/feature, or the plugin/manual tooling creates
`.loci/vault.toml` out-of-band.

**What the record says:** `initialize_vault` exists (`vault/init.py:25`) and is called by
**nothing** outside tests; `Loci.open` never initializes and raises `VaultNotInitialized`
(`kernel.py:85-86`); the old `loci repository.init` wire/CLI command is gone; the current CLI's
surface is registry-derived only. The arch documents the vault manifest (§6.1) but not an init
command.

**Recommendation:** the engine registers init as a first-class verb (CLI `loci init [--vault …]`
and/or a registered feature) — otherwise a fresh vault cannot be created by any supported tool
and the plugin's attach faces an unrecoverable `VaultNotInitialized`. If the author prefers
out-of-band init (manual file creation), the plugin still needs a *surface* for the failure
(P1.2).

---

## Q3 — Diagnostic severity policy

**Fork:** drop `unmanaged` entirely by default (arch §13 endorses hosts filtering it), show it at
hint, or expose a toggle.

**What the record says:** arch §13: "Hosts may filter it out entirely by default." D-047 measured
4,626 `unmanaged` rows (information) on the 5,113-doc vault and states the lever is host-side
filtering. The adapter maps `unmanaged` → severity 3 and labels the message with the bare code.

**Recommendation:** filter `unmanaged` by default; keep a `vim.g.loci_show_unmanaged` (or
`:LociToggleUnmanaged`) escape hatch. Note the per-buffer framing: one `unmanaged` row per
unmanaged note *opened* — so the default filter is about panel hygiene, not volume.

---

## Q4 — Activation / editor-state: keep as plugin-owned, or delete?

**Fork:** re-home workspace→editor-state mapping (git tcd, resession, haunt, wayfinder) inside the
plugin as *new product logic*, or delete it in this realignment.

**What the record says:** arch §6.7/§4.3 explicitly put session state in the host — this is the
*correct* home, and the prompt's ground rules say "the answer is that loci.nvim owns them — not
that the engine should." But the plugin never owned them: it *applied plans the engine returned*
(DeactivationPlan, ActivationPlan editor_state). With no engine plan, a "keep" means designing
and shipping a workspace→editor-state mapping (which workspace activates which session/trail) —
real new product surface, with nix-nvim's keymaps and statusline as co-consumers.

**Recommendation:** **delete for this realignment** (P2.6). The honest client for the current
engine has no activation; resurrecting it is a separate feature with its own design record
(and it would touch nix-nvim, not just this repo). The statusline `loci:<id>` consumer and the
`<leader>lw` activation mapping in nix-nvim need a coordinated removal decision.

---

## Q5 — The palette: rebuild from the registry, or drop?

**Fork:** the palette was the plugin's signature interaction, but its data source (`loci/commands`)
is gone. The registry now defines 24 typed features with request models and docs — the raw
material for a *better* palette — but building it means re-deriving arg specs (the old
`prompt_args` kinds) from dataclass fields.

**Recommendation:** rebuild after P2 stabilizes the typed surface (P3.4-ish), driven by the
registry (wire name + request fields → prompt). Do not rebuild it in the same pass as P2 — the
shape of the typed helpers should settle first. Until then, the direct commands/hubs cover the
surface.

---

## Q6 — The test gate

**Fork:** the Lua harness's real-server tests (t17/t20/t21) were gated on the old binary; the
flake `checks.loci-lsp-tests` re-export (AGENTS.md's "real test gate") is **empty** in the
current engine (no pytest-lsp suite survived the clean-room).

**Recommendation:** while Q1 lands, the Lua suite's server fakes should *import the real adapter*
(01-ANALYSIS §5) so the client tests exercise genuine V2 logic headless; the engine-side gate is
a loci-core decision (whether to restore a pytest-lsp suite). Do not let the flake check claim a
gate that does not exist.

---

## Q7 — `loci` CLI arm

**Fork:** `flake.nix:47-52` re-exports `loci-core.packages.<sys>.loci-core` as `loci`; against V2
that package has no `bin/` (no `[project.scripts]`). Keep the re-export (once scripts return, it
works again), or drop the `loci` package from this flake and let nix-nvim fetch the CLI from
loci-core directly?

**Recommendation:** keep the re-export (it rides the same DAG hop — that was the documented
rationale, `flake.nix:50-52`) and let it come back alive with P0.2's `[project.scripts]`. Note in
docs that `loci` is the CLI arm and `loci-lsp` the LSP arm.
