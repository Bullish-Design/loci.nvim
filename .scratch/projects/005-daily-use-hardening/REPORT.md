# 005 — Daily-use hardening

**Date:** 2026-08-12
**Scope:** the nine outstanding items from projects 003/004 — the CAS save path, a code-action
mystery, the interactive-verification gap, five unexposed engine capabilities, effect-shape ground
truth, the `gitman reconcile` data-loss bug, repo hygiene, diagnostic coverage, and the downstream
consumption path.
**Trigger:** everything project 004 closed was verified against a *fake*. The items below are the
ones that could only be settled against the real engine, a real terminal, or a real repo.

---

## TL;DR

Nine items, three of them real bugs, one of them a bug that was never there.

**The headline finding is a live everyday bug that nobody had looked for.** `:w` on a note created
during the session is refused by the engine — every time, forever, with
`destination_exists` — because neovim writes the file before it sends `didSave`, so the adapter's
create branch finds the file it is about to create already present. The file lands on disk, so it
*looks* fine; the index never takes it. Reproduced on the real server, root-caused in
`loci-core/apps/lsp/adapter.py`, and now covered hermetically (t30).

**The code-action mystery was a defect in the probe, not the product.** The drive passed
`vim.diagnostic.get(0)` — `vim.Diagnostic` rows, which have `lnum`/`col` and no `range` — as
`context.diagnostics`. pygls raises `JsonRpcInvalidParams` while *structuring* the message, before
dispatch, so the server never answers, and the probe recorded the missing reply as `0 actions`. No
client bug exists. The refresh-storm hypothesis is disproven with numbers.

**Two structural gaps are closed rather than patched.** Effects now have their own ground-truth
capture that speaks to a live `loci-lsp` (`capture-effects.py`), and the contract validator covers
`saveResult`, code actions and `loci.action.execute` — the three surfaces the CLI cannot show and
004 therefore never checked. And the suite can now render a real UI and press real keys (t32),
which is what "verified" had been quietly excluding.

Suite: **29 → 33**. `nix flake check` green. Four new `:Loci*` verbs. One product decision is left
for the user: cutting the release that would let any of this reach daily use.

### Method

Ground truth came from the real engine throughout. Every claim about the wire was taken from a live
`loci-lsp` over raw JSON-RPC, never from the CLI (004's addendum explains why, and item 5 makes it
mechanical). Every claim about behaviour was reproduced twice: once against the real server on a
copy of the 5113-note vault, once hermetically. Every regression test was reverted-and-re-run to
confirm it fails against the broken code.

---

## Findings

| # | Item | Verdict | State |
|---|---|---|---|
| F-01 | `:w` on a new note is refused forever (`destination_exists`) | **LIVE bug — engine** | Client handling decided + t30; engine patch specified |
| F-02 | The CAS conflict path is unreachable through neovim | By design, worth knowing | Documented |
| F-03 | Code actions returned 0 in a 60-file session | **Probe artifact** | Root-caused; not a product bug |
| F-04 | `loci-lsp` silently drops a request it cannot deserialise | Latent — engine | Reported |
| F-05 | Interactive flows were never rendered or keyed | **Structural gap** | Closed — TUI driver + t32 |
| F-06 | Five registered capabilities had no editor surface | Gap | Four exposed, one declined |
| F-07 | Effect envelopes were still unvalidated | **Structural gap** | Closed — `capture-effects.py` + contract |
| F-08 | `SourceCommit` was modelled as `{status}`; the wire sends five fields | Latent | Fixed + enforced |
| F-09 | `loci.action.execute` `commit` is a STRING; the fake sent an object | Latent | Fixed + enforced |
| F-10 | The fake padded a refused save with a `revision` the engine omits | Latent | Fixed + enforced |
| F-11 | Code-action `command.arguments[0]` was missing `uri`; `expected_hash` was `"abc"` | Latent | Fixed + enforced |
| F-12 | `undo` of a `reconcile` re-created issue 31's data loss | **LIVE bug — gitman** | Fixed + landed |
| F-13 | Diagnostics: pull route, severity and range were untested | Gap | Closed — t31 |
| F-14 | 13 tracked-but-gitignored files churned every `gitman status` | Hygiene | Fixed |
| F-15 | Nothing since v0.2.1 has ever reached daily use | **Product decision** | Documented, not acted on |

---

### F-01 — `:w` on a new note is refused, every time — LIVE

The reproduction is three lines in a vault:

```
:e New Note.md      " BufNewFile -> didOpen for a file that does not exist
i# hello<Esc>
:w                  " loci: save not committed (New Note.md): destination_exists
```

Verified against the real `loci-lsp` on a copy of the 5113-note vault, and again on a scratch vault
built by `capture-effects.py`. It repeats on **every subsequent `:w` in that session**.

**Root cause** — `loci-core/apps/lsp/adapter.py::did_save`:

```python
base = self._base_hash.get(path)          # recorded at didOpen; None when the file was absent
if base is None:
    result = self.loci.executor.create(path, buf.content)
    if not result.committed:
        return {"committed": False, "reason": result.detail or result.status.value}
```

Neovim writes the file and *then* notifies, so by the time `did_save` runs the file exists and
`executor.create` refuses with `destination_exists`. The early return never advances `_base_hash`,
so the next save takes the same branch — hence "forever".

**The consequence is not the notice.** `ingest_source` is skipped, so a newly created note is not
compiled into the index at save time. It stays invisible to search and to the graph until a
refresh.

> **Correction (2026-08-13, see the addendum).** The last sentence is wrong. It was never measured.
> The LSP host opens the vault at `ConsistencyMode.CURRENT` (`apps/lsp/host.py`), and every current
> read runs a refresh pass, so the note IS visible to search and the graph with no user action.
> Only an `INDEXED` read stays behind, and the host issues none. The refusal is real; this
> consequence is not.

**Recommended engine fix** (loci-core, not authored here):

```python
if base is None:
    result = self.loci.executor.create(path, buf.content)
    if not result.committed:
        # neovim writes the file itself and only THEN sends didSave, so a buffer that did
        # not exist at didOpen already exists here. That is the ordinary new-file save, not
        # a conflict: adopt the bytes on disk when they are the bytes we were going to write.
        try:
            current = self.loci.executor.read(path)
        except OSError:
            return {"committed": False, "reason": result.detail or result.status.value}
        if current.raw == buf.content:
            self.loci.ingest_source(path)
            self._base_hash[path] = str(current.hash)
            return {"committed": True, "revision": str(self.loci.cache.state().revision)}
        return {"committed": False, "reason": result.detail or result.status.value}
```

**Client handling — decided.** The client stays thin and keeps quoting the engine's reason verbatim,
but it now names the consequence and the remedy, because "save not committed" reads as *your text
was lost* when in fact the bytes are safely on disk and it is the **index** that is behind:

```
loci: save not committed (New Note.md): destination_exists
      — the file is on disk but the index did not take it; :LociRefresh to re-scan
```

`:LociRefresh` did not exist — `maintenance/refresh` was reachable only from the palette and the
status hub — so it was added. A "reload from disk" affordance was considered and rejected: nothing
needs reloading in any reachable branch (see F-02), and an unnecessary reload would be a way to lose
buffer content.

Pinned by **t30**, verified to fail without the fix.

### F-02 — the CAS conflict path cannot be reached through neovim

The engine's save is a compare-and-swap against the hash recorded at `didOpen`. All five outcomes
were reproduced (`capture-effects.py` emits every one deterministically), but only some are
reachable from an editor that writes its own files:

| `reason` | Reachable from neovim? | Why |
|---|---|---|
| `ok` | no | needs buffer ≠ disk at didSave |
| `unchanged` | **yes — every ordinary `:w`** | nvim writes first, so disk == buffer |
| `destination_exists` | **yes — every `:w` on a new note** | F-01 |
| `not_open` | yes | didSave for a document the server never saw |
| `source_hash_mismatch` | **no** | same reason as `ok` |
| `unreadable:<errno>` | yes | the file vanished mid-save |

The interesting row is `source_hash_mismatch`, which t13 covers against the fake and which no real
neovim can produce. Provoking it needs a `didSave` that neovim did not precede with a write:

```lua
-- open, edit the buffer only, move the file on disk, then notify by hand
client:notify("textDocument/didSave", { textDocument = { uri = uri } })
--> {committed = false, reason = "source_hash_mismatch"}
```

**This is worth stating plainly: neovim's write-then-notify order defeats the engine's CAS.** When a
file really has changed underneath you, vim's own `E211`/"file changed since reading" prompt is the
guard; forcing past it with `:w!` produces `unchanged` from the engine, which then quietly ingests
the clobbered content. The CAS protects hosts that let the *server* commit the buffer. Neovim is not
one. Nothing to fix in this repo — but the next person to read `did_save` should not conclude that
the editor is protected by it.

t13 keeps its coverage of the notice; t30 adds the branch a user actually meets.

### F-03 — code actions: the probe was broken, not the client

`drive3.lua` reported `0 actions` after opening 60 files; an isolated probe on the same vault
reported 1. The hypothesised cause was a refresh storm. It is not.

**Measured** (`ca2.lua`, real server, 5113-note vault):

| Condition | Reply? | Actions | Latency |
|---|---|---|---|
| cold, 1 buffer | yes | 1 | 18 ms |
| after 60 opens | yes | 1 | 2 ms |
| immediately after the 61-buffer toggle storm | yes | 1 | 113 ms |
| after the storm settled | yes | 1 | 1 ms |

The whole 61-buffer refresh completes in **127 ms**. There is no storm to race.

**The actual cause** is the one line that differs between the probe that worked and the drive that
did not:

```lua
ca.lua   context = { diagnostics = {} }                      --> 1 action
drive3   context = { diagnostics = vim.diagnostic.get(0) }   --> "0 actions"
```

`vim.diagnostic.get()` returns **`vim.Diagnostic`** — `lnum`, `col`, `end_lnum`, `end_col`,
`bufnr`, `namespace` — and **no `range`**. That is not an LSP `Diagnostic`. Confirmed at both ends:

* client side (`ca4.lua`): `replied=false` after 8 s, `err=nil` — the request is never answered;
* server side (`rawca.py`, raw JSON-RPC): the well-formed request either side of it returns 1 action,
  the malformed one gets **no reply at all**, and the server's stderr ends
  `pygls.exceptions.JsonRpcInvalidParams: Invalid Params`, raised in `pygls/io_.py::run_async`
  during `structure_message` — i.e. before dispatch, so no error response is generated either.

The drive collapsed "no reply" into `#actions == 0`, and the report inherited that. **Real neovim
never sends this shape** — `vim.lsp.buf.code_action()` converts through `vim.lsp.diagnostic` — so
there is no user-facing bug here. The lesson is recorded in `.scratch/tests/README.md`: a probe is
not evidence until it can tell "no reply" from "empty reply".

### F-04 — the server silently drops a request it cannot deserialise — engine note

Falling out of F-03: a request whose params fail `lsprotocol` structuring produces **no response of
any kind**, and neovim's `buf_request` has no timeout, so that request hangs for the life of the
session. Low priority (a conforming client will not trigger it) but worth a `try/except` around
`structure_message` that answers with a JSON-RPC error. Filed here rather than fixed — loci-core is
not authored in this repo.

### F-05 — interactive flows were never rendered or keyed — CLOSED

Every test in the suite drove the client by *calling* it, with `Snacks` stubbed and
`vim.ui.select`/`vim.ui.input` replaced. That proves callbacks run. It proves nothing about whether
a prompt draws, and `vim.ui.select` is precisely where it mattered: headless it blocks forever, so
the confirm step of every preview-then-apply flow had never once been answered by a keypress.

**Chosen approach: a child nvim in a terminal buffer.** Three options were considered — a pty
driver, a remote UI, a manual checklist. The terminal buffer wins because nvim already owns both
halves: the parent is headless, the child runs its ordinary TUI inside a real libvterm screen, and
`nvim_buf_get_lines` reads what is actually drawn while `chansend` types into it. No pty helper, no
escape-sequence parsing, no new dependency, and it runs in CI exactly as it runs locally.

`common.spawn_tui` is ~70 lines; **t32** uses it to assert that the workspace picker *draws* with the
server's row, that typing `1<CR>` runs the choice, that preview-then-apply *draws* Apply/Cancel and
that cancelling returns cleanly, and that `vim.ui.input` draws and accepts typed text. Verified to
fail against two deliberate regressions: removing `pick()`'s `vim.ui.select` fallback, and making
`preview_then_apply` apply without confirming.

Two details are load-bearing and cost a debugging cycle each:

* `require("loci")` must run **before** the file is opened. A file passed as argv is already loaded
  when `-c` commands run, so the attach autocmd registers after the only event that would fire it
  and nothing ever attaches. `spawn_tui` opens the file with a second `-c`.
* the test must wait for the client to finish `initialize`. A picker only draws once a reply
  arrives; feeding `:LociWorkspaces` the moment the buffer appears races the attach and flakes.
  `Tui:wait_attached()` makes the child do the waiting and print a sentinel.

**Scope, stated honestly:** this repo cannot render Snacks — the picker is nix-nvim's dependency,
not loci.nvim's, so `pick()` takes its `vim.ui.select` fallback here. What t32 verifies is that
fallback (which is also what a user without Snacks gets), plus inputs, confirms and notifications.
Snacks *visuals* remain unproven and belong downstream, where Snacks exists. Calling that "covered"
would be the same mistake as calling a 2-char revision "a revision".

**The silent-create question — decided: no notice.** Note creation stays silent on success. The
buffer opening is immediate, unambiguous confirmation, and creation is among the most frequent
actions there is; a notice would be pure noise on the happy path. The *failure* path is what needed
a voice, and it has one (004 F-14, and F-01 above).

### F-06 — five registered capabilities had no editor surface

The engine registers 24 wires. Five had no `:Loci*` verb. Per-capability decision:

| Wire | Request | Decision | Reasoning |
|---|---|---|---|
| `relations/add_project` | `{document, project}` | **Expose** — `:LociAddProject` | The real gap. A project is just a document whose kind is `project`; membership lives in the member's owned `loci:` region, and **nothing in the editor could write it**. The engine adopts an unmanaged member first and its preview shows both patches, which `summarize_preview` already renders. |
| `relations/remove_project` | `{document, project}` | **Expose** — `:LociRemoveProject` | Symmetric; a one-way door is not a feature. It must offer *every* project rather than the document's current ones — `documents/get` returns a `DocumentView` with no membership field — and lets the engine refuse `membership unchanged (not a member)`. |
| `documents/set_status` | `{ref, status}` | **Expose** — `:LociSetStatus` | Daily-driver value (the task workflow). The vocabulary is the **vault's**, not the client's: the picker offers the statuses `documents/list` shows already in use, deduped and sorted, plus a free-text escape. Hardcoding a status list would be exactly the client-side semantics this plugin does not hold; the engine refuses anything illegal (`set_status refused: unsupported_new_value`). |
| `documents/format_owned` | `{ref}` | **Expose** — `:LociFormat` | Already offered as a code action, but only while `noncanonical_loci_metadata` is on the document *and* only through the code-action menu. `:LociAdopt` set the precedent that a code action's verb also gets a direct surface. Cheap: it reuses the declared preview route, and a no-op answers `formatted: false` and commits nothing. |
| `documents/preview_adoption` | `{path}` | **Leave engine-only** | It duplicates `documents/adopt/preview`, which the client already uses, in a *different* shape: `{preview: AdoptionPreview}` rather than a `CommandPreview`. Exposing it would mean a second preview renderer for zero user-visible gain. The engine keeps it as a lower-level route for non-preview-route hosts. |

All four verbs were driven against the real server on a scratch vault: `:LociAddProject` adopted the
member and wrote `projects: [<uuid>]`, `:LociSetStatus` offered exactly `{active, ＋ other…}` (the
vault's actual vocabulary) and wrote `status: active`, `:LociFormat` committed, and
`:LociRemoveProject` returned `projects: []`. Pinned hermetically by **t33**.

A side effect worth noting: the vault-relative-path computation was copy-pasted into six verbs. It
is now one `current_ref()` helper, so there is one place to be wrong instead of six.

### F-07 — effect envelopes were still unvalidated — CLOSED

004's addendum diagnosed this and did not close it: `capture-fixtures.sh` says "reads only", and
nothing filled the gap. `capture-effects.py` does. It speaks raw JSON-RPC to a real `loci-lsp`
against a throwaway vault and captures **every** effect surface the client sees:

* all nine mutating wires and their preview routes, each with a refusal variant;
* all five `loci/saveResult` outcomes, driven deterministically;
* `textDocument/codeAction` and the one `workspace/executeCommand`.

`--write-contract` merges the observed key sets, the `SourceCommit` field set, the `saveResult`
required/optional split with its `reason` vocabulary, and the code-action shapes into
`fixtures.json`, which `fs_v2.py` now validates against at startup exactly as it does for reads.

**One trap, recorded in the script and the README:** LSP notifications are queued, so a bare
`didOpen` has not been processed when the call returns. Writing a file straight after sending
`didOpen` lets the server read the *new* bytes as its CAS base, and every conflict probe comes back
`committed` — the capture races itself and reports the happy path. The first run did exactly that.
`Server.sync()` issues a request as a barrier; with it, all five save outcomes reproduce every time.

A second trap, found the same way: **`loci --json documents/create` does not create anything.** The
CLI's mutating verbs return a `CommandPreview` with `_committed: false`. The capture's scratch vault
initially built its project document through the CLI and then could not resolve it. Fixtures for
effects must come from the wire; so must the *setup* for capturing them.

What the capture surfaced, all now fixed and contract-enforced (F-08 … F-11):

| Fake said | Engine says |
|---|---|
| `commit: {"status": ...}` | `{status, path, old_hash, new_hash, detail}` — the whole `SourceCommit` |
| `loci.action.execute` → `commit: {"status": ...}` | `commit: "source_committed"` — a **string** (`adapter.execute_action` projects `commit.status.value`) |
| every `saveResult` carries `revision` | a **refused** save omits it |
| `expected_hash: "abc"` | a 64-char content hash |
| `command.arguments[0]` = `{action_id, path, expected_hash, args}` | …plus `uri`, which the host adds |

Each rejection was verified by reintroducing the exact drift and confirming the fake refuses to
start with a message naming it — nine classes, nine rejections. One check initially did **not**
fire: the validator mirrored the `loci.action.execute` literal instead of reading it, and a mirror
is itself a fixture that can drift. Both that result and the `saveResult` default now live in
`DEFAULTS`, read by the handler and the validator alike.

### F-12 — `gitman undo` re-created the issue-31 data loss — LIVE, fixed

Project 31 in the gitman repo documented `reconcile` resetting `main` backward. Investigating it
found that **most of it had already been fixed** at gitman HEAD (`4f4249f`) — and that one of the
three "blockers" was both still open and mis-specified.

| Fix | Status found | Action |
|---|---|---|
| F1 ancestry-based dispatch | Done, by a **better** predicate | verified |
| F2 non-fast-forward protection | **Open, and incompatible as written** | reformulated + implemented |
| F3 make `undo` honest | Done | verified |
| F4 disclose stakes | Partly | completed |

**F1 shipped as *knownness*, not ancestry, and that is correct.** Ancestry cannot decide the
question: a git-only commit is not in jj's index at all, so `is_ancestor` raises rather than
answering. The shipped test is resolvability — unknown to jj ⟺ git holds history jj never imported
⟹ `git_import`.

**F2 as written ("assert the target is a descendant") would break `undo`,** whose whole job is to
move a ref backward. It also guards the wrong property: a backward ref move is harmless when the
commit stays reachable and harmful when it does not, regardless of ancestry.

**And the hazard it was aiming at is real, still open, and reproducible.** Running the issue's own
repro to the end:

```
gitman reconcile   -> RECONCILED, main adopts the raw commit          (F1 works)
gitman undo        -> UNDONE, "re-pointed colocated git ref(s): main" (F3 works)
gitman status      -> CANONICAL
git log --all      -> the raw commit is reachable from nothing
```

The import put the commit into jj's index, so after the rewind it classifies as `rewrite` (jj knows
it) and force-writing `refs/heads/main` leaves the op log as its only referent. **Issue 31's shape,
relocated from `reconcile` into `undo`, and reported as a clean `UNDONE` on a `CANONICAL` repo.**

Implemented: before a rewrite forces a ref backward, if nothing else would still reach what the ref
named, bookmark it as `adopted-<id>` first. Two guards keep it off ordinary work:

* a **rewritten** commit (`save` amends, `land` rebases) shares its **change id** with its
  successor, so a reachable namesake means "rewritten", not "lost";
* preservation is opt-in per caller and only `undo`-of-`reconcile` opts in. Undoing an ordinary
  intent is *meant* to discard that intent's commit; undoing a `reconcile` discards history that
  arrived from git. After the fact the two are indistinguishable, so the caller who knows says so.

Without the second guard the gitman suite drops **255 → 238**: every `undo` round-trip grows a
spurious `adopted-*` lane. That number is the evidence the narrow gate is the right scope, and it is
why the first attempt at F2 was wrong.

Also fixed: `write_git_ref` failures were swallowed (`except PyjutsuError: pass`), so a ref that
failed to move left the repo desynced behind a success report; ref moves now name **both** commit
ids (`main 91e6df46 -> 7037fa0f`) instead of just the ref; and `reconcile`'s CLI help and the agent
skill, which both described it as stray-adoption only, now state what it does to refs and that
`--abandon` is the one discarding mode.

Landed on gitman `main` (`7a1cec4`) and pushed. Tests:
`test_undo_of_a_reconcile_keeps_the_imported_commit_referenced` (verified to fail without the fix)
and `test_undo_of_a_land_does_not_invent_a_lane` (pins the scope). 255 passing.

### F-13 — diagnostics: pull, severity and range were untested — CLOSED

`fs_v2` did implement the pull route. What was missing is what the tests asserted about it: t12 and
t24 both drive the **push** route and both check `code` alone. So three things had no coverage —
the pull route with its own payload (and it is the route a real session uses, since the engine
advertises `diagnosticProvider` and neovim therefore pulls and never pushes), the four-way severity
map, and ranges. A client that dropped ranges entirely would have passed the whole suite.

**t31** drives the pull route explicitly, asserts the request reaches the server, checks all four
`SEVERITY_BY_CODE` levels map to the right `vim.diagnostic.severity`, checks exact
`lnum`/`col`/`end_lnum`/`end_col`, and checks that `unmanaged` is filtered on the pull route too and
appears when the escape hatch is on. Verified to fail with the pull wrapper disabled.

### F-14 — tracked-but-gitignored churn — CLOSED

Thirteen files under `.agents/devenv/` were tracked while `.gitignore`'s `.agents/**` rule ignored
them, so every `gitman status` reported churn. They are devenv's own reference docs, rewritten on
shell entry — exactly the "platform/tool runtime state" `.gitignore` says stays ignored.

`gitman untrack` removed them from the tree and appended explicit ignore lines. Those lines were
then dropped: `.agents/**` already covers every one of them, and `.gitignore` is an **inherited**
file that CopyRoom reconverges — leaving redundant entries there would have been churn of a second
kind. The file is byte-identical to trunk; the files are still on disk; `gitman status` is clean.

The repo also arrived off-canonical with a stray change (`db44060a`). It was **not** repaired with
the banned path: `jj git import` first, then the stray was adopted into a lane, confirmed to be
content-identical to trunk apart from a `devenv.lock` refresh the working copy already carried, and
abandoned. Trunk never moved.

### F-15 — nothing since v0.2.1 has reached daily use — PRODUCT DECISION

The DAG is `loci-core → loci.nvim → nix-nvim → nix-terminal → nix-meta`. Only **nix-nvim** pins
loci.nvim, and it pins it **by tag**:

```nix
loci-nvim.url = "github:Bullish-Design/loci.nvim?ref=v0.2.1";   # locked to 15a1c5b
```

`nix-terminal` and `nix-meta` do not declare a `loci-nvim` input at all — it reaches them
transitively through `nix-nvim`, and their locks agree at `15a1c5b`.

`v0.2.1` is `15a1c5b`. Everything after it is unreleased: `e7ebf42 feat: complete the V2 surface`
(document verbs, graph pickers, link-a-file, the unmanaged toggle, the statusline segment), all of
project 004's fidelity work, the diagnostics and `E211` fixes, and all of 005. **None of it is in
the fleet.** Landing on `main` changes nothing downstream, because the published interface is the
tag.

The update flow, once a release is wanted:

```bash
# 1. loci.nvim — the tag is the published interface (gitman.toml says so)
gitman release minor                      # bump -> tag vX.Y.Z -> push tag

# 2. nix-nvim — the only direct consumer
#    edit flake.nix:  loci-nvim.url = "github:Bullish-Design/loci.nvim?ref=vX.Y.Z";
nix flake update loci-nvim && gitman save … && gitman land && gitman push

# 3. nix-terminal, then nix-meta — transitive; each just re-locks its parent
nix flake update nix-nvim      # in nix-terminal
nix flake update nix-terminal  # in nix-meta
# 4. rebuild
```

**Not run.** Cutting a tag and re-locking four repos publishes work and changes the user's daily
environment; that is the user's call, not a cleanup task. The flow above is the whole of it.

---

## What went right

Worth recording, because the recommendations should not disturb it:

- **The 004 contract validator paid for itself immediately.** Every fixture correction in F-08…F-11
  was caught, or confirmed caught, by the mechanism 004 built. Extending it to effects was
  incremental rather than novel.
- **`present()`/`list()` discipline held.** Nothing in the new effect shapes crashed the client, and
  the four new verbs inherited the null-safety by using the existing helpers.
- **Preview-then-apply generalised without change.** All four new verbs reuse `preview_then_apply`
  and `summarize_preview` verbatim, including `relations/add_project`'s two-patch preview.
- **The engine's refusal vocabulary is well-formed.** Every refusal encountered — over five wires
  and five save outcomes — arrived as either a typed `{ok: false, error}` envelope or a
  `commit.status` the enum already contains. No new fictions.

---

## Recommendations

**R1 — Fix `did_save`'s create branch in loci-core (F-01).** The exact patch is above. This is the
only item here that a user meets every day, and it is four lines.

**R2 — Answer malformed requests (F-04).** Wrap `structure_message` so an undeserialisable request
gets a JSON-RPC error instead of silence. A hung request with no error is the hardest possible
failure to diagnose from the client — it cost this project a full investigation cycle.

**R3 — Capture effects at the LSP, always (F-07).** `capture-fixtures.sh` for reads,
`capture-effects.py` for effects. Both are re-runnable after an engine change; neither should be
replaced by hand-editing `fixtures.json`.

**R4 — Treat "a probe returned N" as unverified until the probe distinguishes no-reply (F-03).**
Recorded in the README. This is 004's "a fixture is only as good as the thing it was copied from",
one level up: a *measurement* is only as good as its ability to fail honestly.

**R5 — Push Snacks-visual verification downstream.** The TUI driver closes the interaction gap this
repo owns. Picker *appearance* can only be verified where Snacks exists; nix-nvim is the right home
and can reuse `common.spawn_tui` directly.

**R6 — Decide the release (F-15).** Everything above is invisible until a tag moves. If the answer
is "not yet", that is fine — but it should be a decision, not an oversight, and right now nine
commits of shipped work are sitting behind it.

**Suggested order:** R6 (it gates whether any of this matters) → R1 → R3/R4 as standing practice →
R2 and R5 when their repos are next touched.

---

## Appendix — the suite

| Test | Pins | Verified to fail without the fix |
|---|---|---|
| t30 | `:w` on a new note: notice names file, engine's reason, and remedy; the fake does not pad a refused save with `revision` | yes (both halves) |
| t31 | diagnostics pull route, four-way severity map, exact ranges, `unmanaged` filter on pull | yes |
| t32 | a picker draws and answers to a keypress; preview-then-apply draws Apply/Cancel; `vim.ui.input` draws and accepts text | yes (two regressions) |
| t33 | `relations/add_project`, `relations/remove_project`, `documents/format_owned`, `documents/set_status`; the status vocabulary comes from server data | — |

29 → **33 passing**. `nix flake check` green.

## Appendix — real vs fake, effect wires

Captured from a live `loci-lsp` on a scratch vault, 2026-08-12. Reads are in 004's appendix; this
table is the half that capture could not see.

| Surface | Engine | Fake before | Fake now |
|---|---|---|---|
| `commit` on every effect | `{status, path, old_hash, new_hash, detail}` | `{status}` | ✅ five fields, hashes 64-char |
| `documents/create` refused | `document: null`, `commit.status: precondition_failed`, `detail: destination_exists` | n/a | ✅ expressible |
| `documents/format_owned` | `{document, commit, revision, formatted}` | absent | ✅ |
| `documents/set_status` | `{document, commit, revision}` | absent | ✅ |
| `relations/add_project` | `{member, commit, revision, adopted_first}` | absent | ✅ |
| `relations/remove_project` | `{member, commit, revision}` | absent | ✅ |
| `documents/preview_adoption` | `{preview: {path, expected_hash, proposed_id, edits, before_excerpt, after_excerpt, diagnostics}}` | absent | not modelled (engine-only, F-06) |
| preview `changes[]` | 9 keys incl. `content`, `destination`, `edits`, `diagnostics` | 2–4 keys | unchanged (client reads 5; noted) |
| `saveResult` committed | `{uri, committed, revision, reason}` | same | ✅ |
| `saveResult` refused | `{uri, committed, reason}` — **no `revision`** | padded with `revision` | ✅ stripped |
| `codeAction[].data.expected_hash` | 64-char hash | `"abc"` | ✅ |
| `codeAction[].command.arguments[0]` | `{uri, action_id, path, expected_hash, args}` | no `uri` | ✅ |
| `loci.action.execute` | `{applied, commit: "source_committed"}` — a **string** | `commit: {status}` | ✅ |
| `loci.action.execute` unknown | `{applied: false, reason: "unknown action …"}` | n/a | unchanged |
| `documents/adopt` on a missing file | `ok: false`, `error.kind: "FileNotFoundError"` | n/a | engine note: a raw `OSError` leaks as the error kind rather than a `LociError` subclass |

---

## Addendum — 2026-08-13: the engine items, implemented and measured

005 left four items open against loci-core, on the ground that the engine is not authored here.
That reasoning held for *writing the patch* and not for *knowing whether the diagnosis was right*.
Running the client against the local engine checkout closed both.

### A new gate: the client against the engine as WRITTEN

`nix flake check` pins loci-core to a pushed rev, so it only ever proves the client against the
engine as *published*. Engine work sits in the sibling checkout for days first.
**`scripts/check-local-engine.sh`** points the input at `../loci-core` (uncommitted work included)
and runs three gates: the engine's pytest suite, the client suite, and a **wire-contract drift
check** that re-captures the effect contract from the live local `loci-lsp` and diffs it against
`fixtures.json`.

The third gate is the one a passing suite cannot give. `fs_v2.py` validates itself against those
same fixtures, so the fake stays self-consistent while the engine moves underneath it — only a
re-capture sees the ground truth change. Verified both ways: clean today, and it fails when F-10's
drift (a refused save padded with `revision`) is planted. Without `--vault` it re-derives the
effect half only; the script says so rather than implying coverage it does not have.

### F-01 — the diagnosis was right, the stated consequence was not

Reproduced against the local engine, driving the adapter in neovim's order. Both saves refused,
exactly as reported. Then the part 005 asserted without measuring — with the index built *first*,
then the new note:

| consistency | hits for the new note |
|---|---|
| `indexed` | **0** |
| `current`, `verified`, `overlay` | 1 |

The host uses `CURRENT` (`apps/lsp/host.py`). So the note was findable all along, and "it stays
invisible to search and to the graph until a refresh" was true only for a mode the host never
issues. The user-facing damage was the notice itself — a scary warning on every `:w` of a new note
— plus a client hint that prescribed a `:LociRefresh` which does nothing.

**Why the engine's own suite never saw it.** `test_repeated_saves_of_a_created_buffer_all_commit`
lets the *server* write the file. Neovim writes first. That one missing line is the whole bug: the
engine's coverage encoded a host model neovim does not use, so the suite stayed green while every
new note refused.

**Fixed** in `did_save`'s create branch: adopt the bytes on disk when they are the bytes we were
going to write, ingest, advance `_base_hash`, and answer `unchanged` — not `committed`. `unchanged`
is what the sibling branch already answers for "disk equals buffer", and what every *later* `:w` on
that file answers; a create that reported `committed` would make a note's first save differ from all
its later ones for no observable reason. The client is silent on `unchanged`, so the everyday flow
is now silent, which is what it should always have been.

Pinned by two engine tests: the neovim-order save (verified to fail without the fix) and a guard
that a file which appeared with *different* content still refuses.

### F-04 — implemented

`AnsweringProtocol` wraps `structure_message`. A request whose params fail `lsprotocol` structuring
now gets a JSON-RPC `-32602`, then the read loop drops the message as before. The hook works
because `structure_message` acts only on the top-level message, so the `id` is still in hand.
Notifications get nothing, per spec. Two raw-wire tests: the error arrives, and the session keeps
answering afterwards. The first is verified to fail without the fix — and it can observe silence
rather than inherit it, because a regression must fail the suite, not hang it.

### The appendix note — implemented

`documents/adopt` on a missing path answered `error.kind: "FileNotFoundError"`, a Python builtin no
client can be written against. `_read_source` — the choke point every adopt/format/preview path
reads through — now raises `UnresolvedReferenceError` for a missing file and `InvalidSourceError`
for an unreadable one.

### The client's hint, corrected

`SAVE_HINT` lost the half that was false and kept the half that matters:

```
save not committed (fresh.md): destination_exists — your text is on disk; the engine did not commit it
```

"save not committed" reads as *your text was lost*. It never is: neovim writes before it notifies.
That reassurance is what the hint is for. `:LociRefresh` stays a command; it is no longer offered as
a remedy for something that needs none. t30 now asserts the notice does **not** prescribe it.

### What this leaves

R5 (Snacks visuals in nix-nvim) and R6 (the release) are unchanged and still open. R6 now gates
more than it did: the engine fixes above are invisible to the fleet until both repos ship.
