# 004 — Fakeserver fidelity audit

**Date:** 2026-08-12
**Scope:** `.scratch/tests/fakeservers/fs_v2.py` (+ `fs_slow.py`) — the reference implementation of the
V2 wire contract that 24 of the 25 hermetic Lua tests run against.
**Trigger:** A live statusline bug shipped green through the whole suite because `fs_v2` returned a
2-char revision (`"r1"`) where the engine returns a 64-char content hash. Fixed in `55a5f7e`. This
audit asks: **where else is the fake lying, and what else could it be hiding?**

---

## TL;DR

The fake is structurally excellent — framing, envelope shape, preview routes, `saveResult`, code-action
`command` enrichment, and pull-vs-push diagnostics are all faithful. **The failures are in the
*values*, not the *shapes*.** `fs_v2` returns data that is the right type and the wrong size, the wrong
vocabulary, or the wrong cardinality.

Thirteen findings. **One was live and is fixed** (F-01). **Two are HIGH latent** — the fake emits a
value the engine cannot produce (F-02) and omits a field the engine always sends (F-03). The rest are
medium/low latent risks plus one structural gap where the fake's *perfect reliability* hides a client
hang path (F-09) and one where the fake **cannot express a server refusal at all** (F-13).

The recurring pattern: **every fixture value in `fs_v2` was hand-authored to be readable, not to be
representative.** Short tokens, one-row lists, one-word strings. That is a systematic bias toward the
easy case, and every finding below is an instance of it.

### Method

Ground truth was captured by running the **real** `loci` CLI (same envelope as the LSP host — both go
through `LociHost`) against a 5113-note vault, then diffing each response against the corresponding
`fs_v2.DEFAULTS` entry. Engine-side enums and the `saveResult` shape were read from `loci-core`
(`src/loci_core/features/documents.py`, `apps/lsp/server.py`). Client consumption was traced in
`lua/loci/init.lua` to separate **live** bugs from **latent** ones.

---

## Findings

Severity = risk to a user. **Live** = misbehaves today. **Latent** = correct today by luck; the fake
provides no guard, so the next edit to that code path can ship broken.

| # | Finding | Severity | State |
|---|---|---|---|
| F-01 | Revision width: `"r1"` vs 64-char hash | HIGH | **FIXED** (`55a5f7e`) |
| F-02 | `identity_state: "ok"` — a value the engine cannot emit | HIGH | Latent |
| F-03 | `saveResult` omits `uri`, which the engine always sends | HIGH | Latent |
| F-04 | Nested `revision` fields still `"r1"` in 6 places | MEDIUM | Latent |
| F-05 | Search snippet is single-line; real snippets embed newlines | MEDIUM | Latent |
| F-06 | Link text bracketed (`"[[a]]"`) vs bare (`"Note 1"`) | MEDIUM | Latent |
| F-07 | `workspaces/list` rows omit `documents`/`files` | MEDIUM | Latent |
| F-08 | Cardinality: 1–2 rows everywhere vs thousands | MEDIUM | Latent |
| F-09 | `M.doctor()` 4-way barrier never sees a failing sub-request | MEDIUM | Structural |
| F-10 | Ids are `"id-p1.md"`, not UUIDs | LOW | Latent |
| F-11 | `kind`/`status` vocabulary is a 2-value subset of the real one | LOW | Latent |
| F-12 | ~~`__pycache__` enters the nix fileset~~ | — | **WITHDRAWN** — flakes source the git tree |
| F-13 | The fake **cannot** return `ok: false` — no refusal coverage | MEDIUM | Structural |

---

### F-01 — Revision width (FIXED, the archetype)

`_env()` seeded `_revision` with `"r1"`. The engine sends a 64-char content hash
(`bfba77550e4045db...af828`). `M.statusline()` returned it raw, so the segment was 64 characters wide
on a real vault and 2 characters wide in CI. t25 asserted `statusline() == "r1"` and passed.

Fixed in `55a5f7e`: client abbreviates to `REV_WIDTH = 7`; `fs_v2.REVISION` is now a real-width hash;
t25 gained explicit width assertions. **Keep this as the reference case** — it is the only one of the
thirteen that reached a user, and it demonstrates the whole failure mode: the fake was type-correct
and magnitude-wrong, and the test encoded the fake's magnitude as the expectation.

### F-02 — `identity_state: "ok"` is not a value the engine can produce — HIGH

`fs_v2._doc()`:

```python
"identity_state": "ok" if state == "managed" else "degraded",
```

The engine's enum is `IdentityState.NONE | MANAGED | DEGRADED` (`loci-core/src/loci_core/features/documents.py`).
Real `documents/list` returns `"identity_state": "managed"`. **`"ok"` is not in the engine's
vocabulary at all** — the fake invented it.

The client never reads `identity_state` today, so nothing is broken. But this is worse than a wrong
value: it is a *fictional* one. Anyone writing `if doc.identity_state == "ok"` against the fake would
produce code that is dead on every real vault, and the suite would confirm it works. Same class of
error as F-01, one step earlier in the pipeline.

### F-03 — `saveResult` omits `uri` — HIGH

Real (`apps/lsp/server.py:146`): `ls.protocol.notify("loci/saveResult", {"uri": uri, **result})` —
contract shape `{uri, committed, reason, revision}`.

Fake (`fs_v2.py:219-222`): `result = {"committed": True, "reason": "ok", "revision": "r1"}` then
`send(... "params": dict(result))`. **No `uri`.**

The client's handler (`init.lua:1083`) ignores `uri` and raises a global notification regardless of
which buffer produced the save. So a save conflict in buffer A is reported with no indication it was
buffer A. That may be an acceptable product decision — but it was never a *decision*, because the
fake never sends the field, so no test could distinguish "we chose not to attribute" from "we cannot
attribute." **The fake removed the option from the design space.**

Fix the fake first (`{"uri": params["textDocument"]["uri"], **result}`), then decide whether the
client should attribute the warning.

### F-04 — Nested `revision` fields are still `"r1"` — MEDIUM

F-01 fixed `_revision` (the envelope field). Six `DEFAULTS` entries carry a *separate* `revision`
field still set to `"r1"`: `workspaces/put`, `workspaces/archive`, `documents/create`,
`documents/adopt`, `documents/move`, plus the `saveResult` payload. All are 64-char hashes in reality.

Not currently rendered by the client — but F-01 was "not currently a problem" right up until the
statusline shipped. This is the same landmine with the pin still in.

### F-05 — Search snippets: single-line fake vs multi-line reality — MEDIUM

Fake: `"...snippet..."`. Real:

```
"# [Project] 1\n\n[Project] 1 body. See [[Note 4307]].\n"
```

**Real snippets contain embedded newlines.** `M.search()` (`init.lua:842`) builds its row from
`r[4]` (title), `r[3]` (state), `r[1]` (path) — it does *not* use `r[5]`, so this is latent. But a
one-line change to surface the snippet (an obvious future feature — it is the only reason the engine
sends it) would put raw `\n` into Snacks picker rows. The fake would keep passing.

### F-06 — Link text: bracketed vs bare — MEDIUM

| Wire | Fake | Real |
|---|---|---|
| `graph/backlinks` `r[3]` | `"[[a]]"` | `"Note 1"` |
| `graph/broken_links` `r[2]` | `"[[missing]]"` | `"Note 4538"` |

The engine returns the **resolved target name**, not the raw wikilink syntax. Both are rendered:
backlinks as `"%s  (%s → %s)"` (`init.lua:875`), broken links as `"%s → %s"` (`init.lua:654`). So the
fake's display strings do not match what a user sees, and any formatting logic that keys on the
brackets (stripping `[[`/`]]`, say) would be written against a fiction and validated by CI.

### F-07 — `workspaces/list` rows omit `documents`/`files` — MEDIUM

Real row: `{id, name, path, project, archived, documents: [], files: []}`.
Fake row: `{id, name, path, project, archived}`.

The workspace composition flows (`link_file`, and the read-modify-write `workspaces/put` path the fake
goes out of its way to echo correctly) depend on membership lists. The fake models them on
`workspaces/get` but drops them from `workspaces/list` — so client code reading membership off a list
row gets `nil` in test and a real list in production, or vice versa.

### F-08 — Cardinality is 1–2 rows everywhere — MEDIUM

Measured on the real vault: 4631 unmanaged diagnostics, 412 broken links, 80 projects, 50 search
results, 13 orphans, 10 distinct diagnostic kinds. `fs_v2` returns **one or two rows for every single
wire**, and `diagnostics_summary` has exactly one entry (`[["unmanaged", 2]]`) against the real ten.

Consequences none of the tests can see: picker behaviour at scale, truncation, sort stability,
`render_health`'s group counts, and the `#list > 0` branches that are effectively always-1 in CI.
`LociDoctor` took 1894 ms and produced 12 health rows on the real vault; the hermetic suite exercises
that path with 1.

### F-09 — The doctor barrier never sees a failure — MEDIUM (structural)

`M.doctor()` (`init.lua:680-697`) sets `pending = 4` and decrements it **only inside each success
callback**. If any of the four graph requests errors, times out, or the server dies mid-flight,
`pending` never reaches 0, `render_health` is never called, and **the command silently does nothing** —
no picker, no notice, no error.

`fs_v2` answers every request, always, so no test can reach this path. This is the one finding where
the fake's *reliability* — not its values — is the problem: a fake that never fails cannot test
failure handling. Worth fixing in the client (a timeout or an error-decrement) regardless of the fake.

### F-10 — Ids — LOW

Fake: `"id-" + basename` → `"id-p1.md"`. Real: UUIDs (`019ff76e-1b9d-7000-afa3-aac4e98a4727`,
`7527c974-673b-44f6-81ee-7a2214a96604`). Length and format both differ; the fake's ids also embed
`.md`, which a naive `id:gsub("%.md$", "")` would corrupt. Low risk, same family as F-01.

### F-11 — `kind` / `status` vocabulary is a subset — LOW

Fake emits `kind ∈ {"project", nil}` and `status ∈ {"active", nil}`. The real vault returns
`kind ∈ {"daily", "task", "project", nil}` and `status ∈ {"active", "waiting", "duplicated"}`.
`M.projects()` and the palette filter on these; neither is tested against the real vocabulary. Note the
real vault surfaced a project whose status is `"duplicated"` — a state the fake has no way to represent.

### F-12 — ~~`__pycache__` enters the nix fileset~~ — **WITHDRAWN (not a defect)**

**This finding was wrong.** It was filed as "unverified" and verification disproved it.

A flake's source is the **git tree**, not the working directory. `lib.fileset` narrows what is
copied, but it can only narrow what nix already sees, and nix never sees untracked files.
`__pycache__` is untracked, so it has never entered the source derivation and there is no hash
churn to fix. A `fileset.difference` filter was written and then reverted as dead weight.

**The real lesson is the inverse of the finding, and it is worth more than the finding was:** a new
test file that is not tracked by git is *invisible to `nix flake check`*. Both new tests (t26, t27)
passed locally via `run-tests.sh` — which reads the working directory — and simultaneously failed
in the sandbox with `E5108: cannot open .../t26_refusal_envelope.lua`, because they were still
untracked. `flake.nix` now carries a comment recording this, since the failure mode is silent in
one direction (a stale tracked file keeps passing) and confusing in the other.

### F-13 — The fake cannot express a refusal — MEDIUM (structural)

`handle_request` ends with:

```python
send({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
```

`ok` is **hardcoded `True`**. The `RESPONSE_FILE` override mechanism substitutes the `value`, not the
envelope — so there is **no way to make `fs_v2` return `{ok: false, error: ...}`**. The engine's typed
refusal path (D-028 name validation, `VaultPolicyError`, CAS conflicts) is therefore untestable in the
hermetic suite. It is covered exactly once, in t17, against the real server.

That is thin coverage for the entire error surface of a client whose job is to render server errors.
The fix is small: let an override supply a full envelope (`if "ok" in override: send(override)`),
then add refusal scenarios for each mutating verb.

---

## What the fake gets right

Worth stating, because the recommendations should not disturb it:

- **Framing and lifecycle** — Content-Length parsing, EOF exit *and* `exit`-notification exit, the
  graceful-shutdown hygiene called out in the README.
- **Envelope discipline** — `{ok, value}` with `_revision`/`_consistency` appended by `_env()`,
  exactly where the CLI adds them.
- **The raw-vs-envelope distinction** — `textDocument/codeAction` returns a bare array and
  `textDocument/diagnostic` returns raw `{kind, items}`, both correctly *outside* the feature
  envelope. This is subtle and right.
- **Code-action `command` enrichment** — mirrors the real host's tiny-code-action accommodation.
- **Request-echoing previews** — `documents/move/preview` and `adopt/preview` plan against the
  request's paths rather than static fixtures, which is genuinely faithful modelling.
- **`workspaces/put` composition echo** — models the wholly-owned-manifest semantics correctly.

The structural fidelity is good. It is the fixture data that needs work.

---

## Recommendations

**R1 — Golden-capture the fixtures (addresses F-02, F-04, F-05, F-06, F-07, F-10, F-11).**
Stop hand-authoring `DEFAULTS`. Add a script that runs the real `loci --json <wire>` against the
representative vault and writes the captured envelopes to a `fixtures/` file `fs_v2` loads. Trim
volume for speed, but keep **one real row verbatim per wire** so widths, vocabularies, and nesting are
the engine's, not an author's. This converts an entire class of finding into a non-issue and stops it
recurring.

**R2 — Assert vocabulary membership, not equality (F-02, F-11).**
Where the client branches on an enum, the test should assert the value is in the engine's set. A fake
value outside the set should fail loudly rather than silently define a fiction.

**R3 — Make the fake able to fail (F-13, F-09).**
Two small changes: let `RESPONSE_FILE` override the whole envelope so `ok: false` is expressible, and
add an opt-in "drop this method" mode so a request can go unanswered. The second directly enables a
regression test for F-09's silent hang.

**R4 — Add a scale fixture (F-08).**
One scenario backed by a few hundred rows, asserting the pickers and `render_health` still render
correctly. Does not need to be every test — one is enough to catch truncation and formatting.

**R5 — Fix F-03 in the fake, then decide the client behaviour.**
Send `uri` because the engine sends it. Then make an actual decision about per-buffer attribution of
save conflicts.

**R6 — Adopt a standing rule.**
*A fixture value must be the same **shape, width, and vocabulary** as the engine's, even when the test
only cares about one field.* Every finding here is a violation of that one rule. If it had been in
place, F-01 would not have shipped.

**Suggested order:** R5 + R3 (small, unblock real coverage) → R1 (removes the whole class) → R2, R4 →
R6 as a note in `.scratch/tests/README.md`. F-09 is a genuine client bug and should be fixed on its
own merits, independent of the fake.

---

## Appendix — real vs fake, by wire

Captured from the real CLI against `/tmp/loci-drive/vault` (5113 notes), 2026-08-12.

| Wire | Real (abridged) | Fake |
|---|---|---|
| `workspaces/list` | `{id: uuid, name, path, project: null, archived, documents: [], files: []}` | same minus `documents`/`files` |
| `documents/list` | `identity_state: "managed"`, `kind: daily\|task\|project`, `status: active\|waiting\|duplicated`, uuid ids | `identity_state: "ok"`, `kind: project\|null`, `status: active\|null`, `"id-<basename>"` |
| `search/text` | `[path, uuid, "managed", title, "# [Project] 1\n\n…\n", -2.706]` | `[path, "id-a", "managed", "Note A", "...snippet...", -1.2]` |
| `graph/backlinks` | `[path, "wikilink", "Note 1"]` | `[path, "wikilink", "[[a]]"]` |
| `graph/broken_links` | `[path, "Note 4538", "wikilink"]` ×412 | `[path, "[[missing]]", "wikilink"]` ×1 |
| `graph/neighbors` | flat paths ×2 | flat paths ×2 ✅ |
| `graph/traversal` | `[path, depth]` ✅ | `[path, depth]` ✅ |
| `graph/orphans` | flat paths ×13 | flat paths ×1 |
| `maintenance/refresh` | 64-char revision, `changed_sources: 0`, 10 diagnostic kinds (max 4631) | `"r2"`, 1 kind (`unmanaged`, 2) |
| `saveResult` | `{uri, committed, reason, revision}` | `{committed, reason, revision}` — **no `uri`** |
| envelope | `_revision` 64-char, `_consistency` | fixed in `55a5f7e` ✅ |
| `ok` | `true` **or** `false` + typed error | always `true` — not expressible |
