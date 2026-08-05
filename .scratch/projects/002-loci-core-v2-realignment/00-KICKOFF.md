# 00 — Kickoff: loci.nvim ↔ loci-core V2 realignment

**Date:** 2026-08-05
**Analyst session:** started at the loci.nvim repo root per `loci-core/.scratch/projects/31-blue-sky-v2-refactor/04-LOCI-NVIM-ANALYSIS-PROMPT.md`.
**Scope:** analysis only. No `lua/loci/init.lua` or test modifications were made in this pass.

---

## Step 0 — Baseline (recorded verbatim)

### Repo state

```
$ git -C loci.nvim log --oneline -5
18c575a chore(release): v0.1.4 — expose the `loci` CLI to consumers
97f77e0 
e740059 chore(gitman): wire the release-tag semver source
a209f83 feat(flake): re-export loci-core's `loci` CLI as packages.loci
ab44b52 docs(scratch): update suite runtime estimate (t20/t21 add real-server waits)

$ git -C ../loci-core log --oneline -3
c6cc3a4 project31: implementation log, final measurements, and the closing sweep
aa1f86a fix: F-23 misc — changed_sources count, LSP index cache, test hygiene
4e462ae feat: F-18 emit the promised diagnostic families

$ git -C ../loci-core branch --show-current
refactor/blue-sky-v2-findings
```

Working tree: `loci.nvim` has two pre-existing local modifications (`.scratch/tests/README.md`, `.scratch/tests/run-tests.sh`) — present before this session, untouched.

### The flake.lock pin

`loci.nvim/flake.lock:20-40` pins `loci-core`:

```
"loci-core": { "locked": { "lastModified": 1785806245, "ref": "main",
  "rev": "d96712646705c5e113537a31d6b078d63285dd83", "revCount": 196, ... } }
```

`d9671264` ("fix(flake): wire knappy 1.1.1 into the loci-lsp-tests env", 2026-08-03) is an ancestor of **both** `main` (e027e57) and `refactor/blue-sky-v2-findings` (c6cc3a4). It is **pre-V2**: `main`'s history shows `bcdfdc1 merge: blue-sky V2` above it, and at that rev `pyproject.toml` still carries `[project.scripts] loci = "loci_core.cli:main"` and the flake still exports `packages.<sys>.{knappy, loci-core, loci-lsp, default}` + `checks.<sys>.loci-lsp-tests`.

**Answer to Step 0.2:** loci.nvim pins a **pre-V2** loci-core rev. It is not currently broken; it breaks on the **next** `nix flake update loci-core` (or any input bump), which pulls the V2 engine into the lock.

### Builds (exact output)

| Command | Result |
|---|---|
| `nix build .#loci-lsp` | ✅ `/nix/store/xdi135rkz7bs85y2nf3v35pk4raahml6-loci-lsp-0.0.1` (bin/ has `loci-lsp`) |
| `nix build .#loci-nvim` | ✅ `/nix/store/7pravdn72hic6nipwwsckidc4zdi0mzb-vimplugin-loci-nvim-0-unstable-2026-08-03` |
| `nix build .#loci` | ✅ `/nix/store/6bq9dxgdrf72c31ng0mgr8s8r4vwfc1f-python3.13-loci-core-0.2.0` (bin/ has `loci`) |
| `nix build --override-input loci-core path:../loci-core .#loci-lsp` | ❌ `error: attribute 'loci-lsp' missing` at `flake.nix:46:22` |

### Test suite

```
$ bash .scratch/tests/run-tests.sh
… 23 passed, 0 failed
```

All 23 invocations (21 test files; t14 ×2 cases, t18 ×2 cases) pass against the **pinned pre-V2 engine** — the fakeservers for t01–t16/t19, the real old `loci-lsp` binary for t17/t20/t21.

### Plugin read (Step 0.5, before engine code)

`lua/loci/init.lua` read end-to-end (1,161 lines). Its header (lines 1–18) declares the contract it was written against: `loci/op` reads, `workspace/executeCommand` effects, pushed diagnostics, code actions, and the `loci/commands` palette, with "every semantic decision server-side in `loci_core.control.*`". The full capability inventory is in `01-ANALYSIS.md`.

---

## Verdict on the prompt's "known breakage" list

| Lead | Verdict | Evidence |
|---|---|---|
| **A. Build edge gone (highest severity)** | **CONFIRMED as an incoming break; REFUTED as a current one.** The engine-side claims are exact — current loci-core exports only `packages.<sys>.{loci-core, default}` (`loci-core/flake.nix:40-43`) and `pyproject.toml` has **no** `[project.scripts]` at all; neither `loci-lsp` nor a `loci` binary exists. But the lock pins a pre-V2 rev (above), so all three `nix build .#…` targets are **green today**. The override build reproduces the eval failure exactly. | `flake.lock:20-40`, `loci-core/flake.nix:40-43`, `loci-core/pyproject.toml:1-60` (no scripts key), build table above |
| **B. Protocol loci.nvim speaks does not exist** | **CONFIRMED.** The V2 adapter (`apps/lsp/adapter.py`) has exactly: `initialize` (65), `did_open` (73), `did_change` (82), `did_save` (89–129), `did_close` (131), `diagnostics` (140), `code_actions` (160), `execute_action` (179). There is no `loci/op`, no `workspace/executeCommand`, no `loci/commands`, no completion. The old server's handlers (`loci/workspace/current`, `loci/op`, `loci/commands`, completion) at the pinned rev are all absent from the adapter. | `apps/lsp/adapter.py` (whole file), `git show d9671264:lsp/loci_lsp/server.py` |
| **C. Capabilities V2 deleted on purpose** | **CONFIRMED** for every item: content jail (arch §6.1 "Content is not confined beneath an engine-owned content jail"), activation/current pointer (§6.7 "no shared `current`…", §11.2 "editor-state and global activation operations leave core"), `documents.delete`/`set_title`/`set_tags` (§11.2 + §18), intent log/sidecars/doctor/reconcile (§18 deletions). | arch §6.1, §6.7, §11.2, §18 |
| **D-047 four diagnostic families** | **CONFIRMED** (compiler emits `unmanaged`/`missing_target`/`ambiguous_link`/`degraded_identity`; adapter maps `unmanaged` → severity 3). **Minor correction:** D-047's measured count is **4,626** `unmanaged` rows on the 5,113-doc vault, not the prompt's 4,631. Also: the flood is *per open buffer* (adapter `diagnostics(uri)` serves one buffer's rows), i.e. one `unmanaged` info row per unmanaged note opened — the "drown" risk is real but per-buffer, not per-vault. | `apps/lsp/adapter.py:148`, D-047 table, `src/loci_core/compiler/` emission |
| **D-041 real UTF-16 ranges** | **CONFIRMED.** `_lsp_range` via `BytesLineIndex.span_to_utf16` with `(0,0)` fallback only where the analyzer has no span (`adapter.py:38-46, 140-155`). | `apps/lsp/adapter.py:38-46` |
| **D-041 did_save dict + CAS** | **CONFIRMED.** `did_save` returns `{committed, reason/revision}` and CASes against the hash captured at `did_open` (`adapter.py:73-80, 89-129`). | `apps/lsp/adapter.py:89-129` |
| **D-032 --json previews** | **CONFIRMED.** `cli/main.py:176-186`: `feature.preview is not None and not apply` → preview, JSON mode stamps `_committed: False`. | `apps/cli/main.py:176-186` |
| **D-030 wire surface 11 → 20** | **CONFIRMED but stale.** The current surface is **24 unique wire names** (8 documents, 1 maintenance, 2 relations, 9 search/graph, 4 workspaces). The surface grew past D-030's 20 (F-12 registered the remaining graph queries). | `.venv/bin/python` registry introspection (48 registry keys = 24 features × name+wire) |
| **D-027 set_status refuses** | **CONFIRMED.** Refusal path raises `InvalidRequestError: set_status refused: unsupported_new_value`; 7/23 sampled values refused (D-027 table). | D-027, `features/documents.py` `_set_status` |
| **D-028 create validates names** | **CONFIRMED.** `_FORBIDDEN_NAME_CHARS` rejects `/`, `\`, NUL, leading/trailing dot/space; `documents/create` never commits a broken document. | `features/documents.py:53-61` |
| **D-045 VaultPolicyError on no FTS5** | **CONFIRMED.** `Loci.open` raises `VaultPolicyError("this SQLite build lacks FTS5…")` at `kernel.py:96`. | `src/loci_core/kernel.py:96` |
| **D-023 changed_sources is a count** | **CONFIRMED.** `RefreshResult.changed_sources: int`; kernel sets it to `len(delta.upserts) + len(delta.removals)` (`kernel.py:150`). | `features/maintenance.py:23-27`, `kernel.py:150` |
| **D-029 archive preserves composition + CAS** | **CONFIRMED.** D-029 (b): round-trip the manifest, replace only `archived`, CAS on the hash read; `InvalidRequestError: archive write refused: source_hash_mismatch` on conflict. | D-029 |
| **Consistency modes explicit** | **CONFIRMED.** CLI defaults to `indexed` and prints mode + revision on every result (`cli/main.py:184-196`). | `apps/cli/main.py:184-196` |
| **Unverified lead — `loci` CLI bootstrap path** | **WORSENED (not in the prompt's list).** `loci repository.init` (used by `docs/README.md` and `t20`) is gone: the current CLI exposes only the 24 registered features, and `initialize_vault` is called by **nothing** but tests. There is currently **no wire, CLI, or flake path that initializes a vault**; `Loci.open` raises `VaultNotInitialized` (`kernel.py:85-86`). The plugin's vault-bootstrap story is fully dead, not just the LSP surface. | `apps/cli/main.py` (registry-derived commands only), `grep -rn "initialize_vault" apps/ src/` (no callers outside tests), `vault/init.py:25` |

### Things the prompt understated

1. **The adapter's `initialize` does not advertise save support.** `adapter.py:65-66` returns `"textDocumentSync": 1` (full-sync number form), which per the LSP spec does **not** register `didSave` notifications — yet `did_save` is the CAS commit path (D-041). Whether nvim's client sends `textDocument/didSave` regardless of that capability must be verified with a live host; if not, the CAS save path never fires. (nobody tests this today — see 01-ANALYSIS §5.)
2. **The plugin's code-action glue depends on `.command` on actions; V2 actions carry `data.action_id`.** The prompt noted the shape change implicitly; it is worth stating as a hard break of `vim.lsp.commands` interception (`init.lua:566-583`), not a re-map.
3. **The `loci` CLI package re-export (`flake.nix:47-52`) currently works only because the pinned rev's pyproject has `[project.scripts]`.** Against V2 the same flake line evaluates to a package with no `bin/` at all — the CLI arm dies with the LSP arm.

---

## Bottom line

`loci.nvim` is **green today and red on the next lock update**. Every line of the prompt's "known breakage" list survives verification except two numbers (20 → 24 wire names; 4,631 → 4,626 unmanaged rows) and the framing of §A (currently pinned pre-V2, not already broken). One new breakage not in the list: the **vault bootstrap path** (`repository.init`) is gone from the current engine with no replacement anywhere in the wire/CLI surface.
