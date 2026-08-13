#!/usr/bin/env python3
"""Fake loci-lsp (V2 wire) over stdio (Content-Length framing).

Reference implementation of the contract in
.scratch/projects/002-loci-core-v2-realignment/04-WIRE-CONTRACT.md:

  * standard LSP: initialize (object-form textDocumentSync WITH save:true),
    didOpen/didChange/didSave/didClose, publishDiagnostics push, codeAction
    (data.action_id + command field), workspace/executeCommand;
  * feature methods `loci/<wire_name>` -> CLI envelope {ok, value} with
    _revision/_consistency appended; `loci/<wire_name>/preview` -> CommandPreview;
  * `loci/saveResult` notification after every didSave (CAS result);
  * hygiene: exit on stdin EOF AND on the `exit` notification (see README).

Config (argv wins, env falls back): LOG, RESPONSE_FILE (JSON dict method -> value
overrides), DIAGNOSTICS_FILE (JSON list pushed after didOpen). LOG records every
request as `req <method> <params-json>` plus every saveResult as `save <json>`.

Two RESPONSE_FILE keys are structural rather than per-method values:
  * `"__drop__": ["loci/graph/orphans", ...]` — never answer these methods, so a
    test can exercise the client's no-reply path (004 F-09).
  * an override dict carrying an `"ok"` key is sent as the WHOLE envelope, so
    `{"ok": false, "error": {...}}` refusals are expressible (004 F-13).

FIDELITY (004): fixture values must match the engine's shape, width, and
vocabulary — see the block above DEFAULTS and `capture-fixtures.sh`.
"""
import json
import os
import sys

LOG = (sys.argv[1] if len(sys.argv) > 1 else None) or os.environ.get("FS_LOG")
RESPONSE_FILE = (sys.argv[2] if len(sys.argv) > 2 else None) or os.environ.get("FS_RESPONSE")
DIAGNOSTICS_FILE = (sys.argv[3] if len(sys.argv) > 3 else None) or os.environ.get("FS_DIAGNOSTICS")

_overrides = {}
if RESPONSE_FILE and os.path.exists(RESPONSE_FILE):
    with open(RESPONSE_FILE) as f:
        _overrides = json.load(f)

_diags = []
if DIAGNOSTICS_FILE and os.path.exists(DIAGNOSTICS_FILE):
    with open(DIAGNOSTICS_FILE) as f:
        _diags = json.load(f)


def log(line):
    if LOG:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def send(obj):
    payload = json.dumps(obj).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
    sys.stdout.buffer.flush()


def read_msg():
    headers = b""
    while b"\r\n\r\n" not in headers:
        chunk = sys.stdin.buffer.read(1)
        if not chunk:  # stdin closed (spawning nvim exited/crashed) -> stop spinning
            sys.exit(0)
        headers += chunk
    _, rest = headers.split(b"\r\n\r\n", 1)
    length = 0
    for line in headers.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1].strip())
    body = rest
    while len(body) < length:
        body += sys.stdin.buffer.read(length - len(body))
    return json.loads(body)


# ---- scripted feature values (the contract shapes; tests override per method) ----

# ---- fidelity constants (project 004) ---------------------------------------
#
# THE RULE (004 R6): a fixture value must have the same SHAPE, WIDTH, and
# VOCABULARY as the engine's, even when the test only cares about one field.
# Every finding in 004-fakeserver-fidelity-audit was a violation of it — most
# notably a statusline bug that shipped green because this file returned a
# 2-char revision where the engine returns a 64-char hash.
#
# Ground truth for every value below was captured from the REAL engine via
# `loci --json <wire>` against the representative vault; see capture-fixtures.sh
# to re-capture after an engine change.

# The engine's `_revision` is a full 64-char content hash, NOT a short token.
REVISION = "36df3e971186d143265440d83e223052b48d2d17843e4696d8f5d66190c84455"
# maintenance/refresh reports a *different* revision than the ambient envelope in
# some flows; keep a second real-width hash so tests can tell them apart.
REVISION_2 = "bfba77550e4045db186de27411524127c11a197db8640f82fcb2b10bd6daf828"
# Content hashes are the same width as revisions. `SourceCommit.old_hash/new_hash`
# and a code action's `expected_hash` are all 64-char hashes on the wire; the code
# action's used to be the 3-char token "abc" (005).
HASH_A = "9ceceefd6dbdaadc39af1b3c25d7ab8352b691c535ca2c9e1aa6e333b1cd730e"
HASH_B = "0d51ebb5b1c8e91f7d0058af192ee8cb91b1c001d6b7dabb50acfec3f22c84ad"

# The engine's IdentityState enum is NONE | MANAGED | DEGRADED (loci-core
# features/documents.py). This file used to emit "ok", a value the engine cannot
# produce — a fiction the whole suite would have validated (004 F-02).
IDENTITY_STATES = ("none", "managed", "degraded")
# Real vocabularies, widened from the old {project, None} / {active, None} pair
# so client filters meet the values a real vault actually contains (004 F-11).
KINDS = (None, "daily", "task", "project")
STATUSES = ("active", "waiting", "duplicated")

# Real ids are UUIDs, not "id-<basename>" (004 F-10). Stable per path so tests
# can still assert on a known id without hand-writing one.
_IDS = {
    "projects/p1.md": "d186b97b-c1f8-4fb8-8af9-3272417762ab",
    "notes/a.md": "7527c974-673b-44f6-81ee-7a2214a96604",
    "notes/b.md": "2c5e9ebb-023c-4a02-9304-66037237e682",
    "notes/c.md": "fe9ff155-b7f2-4d8d-b82e-c9401a0c386d",
    "notes/x.md": "019ff76f-0461-7000-8a27-0b791c9f6c79",
}


def _uuid_for(path):
    """A stable, real-shaped (36-char, 5-group) UUID for any fixture path."""
    if path in _IDS:
        return _IDS[path]
    h = f"{abs(hash(path)):032x}"[:32]
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def _commit(status, path, old_hash=None, new_hash=None, detail=None):
    """One SourceCommit, shaped exactly as an EFFECT returns it over the wire.

    All five fields, always: the engine serialises the whole dataclass
    (loci-core fs/outcomes.py). This file used to send `{"status": ...}` alone —
    the same class of under-modelling as the 2-char revision, and invisible to
    the 004 audit because that capture read the CLI, whose effect projection has
    no `commit` at all (see capture-effects.py).
    """
    return {"status": status, "path": path, "old_hash": old_hash, "new_hash": new_hash, "detail": detail}


def _doc(path, title=None, kind=None, state="managed", status="active"):
    """One DocumentView, shaped exactly as `documents/list` returns it.

    The engine sends `status` for EVERY managed document (not just projects) and
    `identity_state` from the IdentityState enum — both corrected per 004.
    """
    return {
        "path": path, "id": _uuid_for(path), "kind": kind,
        "title": title if title is not None else path.split("/")[-1],
        "status": status if state == "managed" else None,
        "state": state,
        "identity_state": "managed" if state == "managed" else "none",
    }


def _env(method, value):
    """Append _revision/_consistency to every feature value (the CLI does this for
    every result — all feature handlers return SnapshotResult)."""
    if isinstance(value, dict):
        out = dict(value)
        out.setdefault("_revision", REVISION)
        out.setdefault("_consistency", "current")
        return out
    return value


# Membership rows, shaped exactly as the engine sends them (captured 2026-08-13
# from a real loci-lsp `workspaces/get`):
#
#   documents -> [id, role, resolved_id, state, path]   — FIVE fields
#   files     -> [path, role]                           — two
#
# Both lists were `[]` here until then. That is the 004 F-07 defect one level
# down: the KEY was present, so the fake looked faithful, but no test ever saw a
# populated row — and `link_file`'s read-modify-write round-trips exactly these
# rows. It read `d[1]`/`d[2]` off a list that was always empty under test.
_WS_DOC_ROW = ["019ffcd4-f279-7000-ad25-32f2a533863d", "primary",
               "019ffcd4-f279-7000-ad25-32f2a533863d", "resolved", "projects/p1.md"]
# NOT `note.md`: that is the file t18 links, and a pre-existing row for it would
# trip link_file's own duplicate refusal instead of the path under test.
_WS_FILE_ROW = ["notes/existing.md", "reference"]

DEFAULTS = {
    # Real `workspaces/list` rows carry `documents`/`files` too — the fake used to
    # model membership only on `workspaces/get`, so list-row membership reads were
    # nil under test and populated in production (004 F-07).
    "loci/workspaces/list": {
        "workspaces": [
            {"id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None,
             "archived": False, "documents": [list(_WS_DOC_ROW)], "files": [list(_WS_FILE_ROW)]}
        ]
    },
    "loci/workspaces/get": {
        "view": {
            "id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None,
            "archived": False, "documents": [list(_WS_DOC_ROW)], "files": [list(_WS_FILE_ROW)],
        }
    },
    "loci/workspaces/put": {
        "workspace_id": "ws-2", "path": ".loci/workspaces/ws2.yaml", "commits": [],
        "adopted_members": [], "revision": REVISION,
    },
    "loci/workspaces/archive": {
        "view": {"id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None,
                 "archived": True, "documents": [], "files": []},
        "commit": _commit("source_committed", ".loci/workspaces/ws1.yaml", HASH_A, HASH_B),
        "revision": REVISION,
    },
    "loci/workspaces/archive/preview": {
        "command": "workspaces/archive", "refusals": [],
        "changes": [{"kind": "update", "path": ".loci/workspaces/ws1.yaml",
                     "before_excerpt": "archived: false", "after_excerpt": "archived: true"}],
    },
    "loci/workspaces/put/preview": {
        "command": "workspaces/put", "refusals": [],
        "changes": [{"kind": "create", "path": ".loci/workspaces/ws2.yaml",
                     "after_excerpt": "schema: 1\nname: NEW"}],
    },
    # Kind/status span the REAL vocabularies (KINDS/STATUSES). The old pair
    # {project, None} x {active, None} never exercised a client filter against
    # values a real vault actually contains — e.g. status "duplicated" (004 F-11).
    "loci/documents/list": {
        "documents": [
            _doc("projects/p1.md", title="P1", kind="project", status="duplicated"),
            _doc("notes/a.md", title="Note A", kind=None, status="active"),
            _doc("notes/b.md", title="Note B", kind="task", status="waiting"),
            _doc("notes/c.md", title="Note C", kind="daily", status="active"),
        ]
    },
    "loci/documents/get": {"document": _doc("projects/p1.md", title="P1", kind="project")},
    "loci/documents/create": {
        "document": _doc("notes/x.md", title="x", kind=None),
        "commit": _commit("source_committed", "notes/x.md", None, HASH_B),
        "revision": REVISION,
    },
    "loci/documents/adopt": {
        "document": _doc("notes/a.md", title="a"),
        "commit": _commit("source_committed", "notes/a.md", HASH_A, HASH_B),
        "revision": REVISION,
    },
    "loci/documents/adopt/preview": {
        "command": "documents/adopt", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "", "after_excerpt": "loci: id-a"}],
    },
    # The four capabilities the client gained a surface for in 005. Shapes captured
    # from a live loci-lsp (capture-effects.py): `format_owned` carries `formatted`,
    # `add_project` carries `adopted_first`, and both relations verbs answer with
    # `member` rather than a DocumentView.
    "loci/documents/format_owned": {
        "document": _doc("notes/a.md", title="Note A"),
        "commit": _commit("source_committed", "notes/a.md", HASH_A, HASH_B),
        "revision": REVISION, "formatted": True,
    },
    "loci/documents/format_owned/preview": {
        "command": "documents.format_owned", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "loci:\n  schema: 1\n  id: 7527c974",
                     "after_excerpt": "loci:\n  schema: 1\n  id: 7527c974\n  projects: []"}],
    },
    "loci/documents/set_status": {
        "document": _doc("notes/a.md", title="Note A", status="waiting"),
        "commit": _commit("source_committed", "notes/a.md", HASH_A, HASH_B),
        "revision": REVISION,
    },
    "loci/documents/set_status/preview": {
        "command": "documents.set_status", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "status: active\n", "after_excerpt": "status: waiting\n"}],
    },
    "loci/relations/add_project": {
        "member": "notes/a.md",
        "commit": _commit("source_committed", "notes/a.md", HASH_A, HASH_B),
        "revision": REVISION, "adopted_first": False,
    },
    "loci/relations/add_project/preview": {
        "command": "relations.add_project", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "  projects: []",
                     "after_excerpt": "  projects:\n    - d186b97b-c1f8-4fb8-8af9-3272417762ab"}],
    },
    "loci/relations/remove_project": {
        "member": "notes/a.md",
        "commit": _commit("source_committed", "notes/a.md", HASH_B, HASH_A),
        "revision": REVISION,
    },
    "loci/relations/remove_project/preview": {
        "command": "relations.remove_project", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "  projects:\n    - d186b97b-c1f8-4fb8-8af9-3272417762ab",
                     "after_excerpt": "  projects: []"}],
    },
    "loci/documents/move": {
        "document": _doc("notes/b.md", title="b"),
        "commit": _commit("source_committed", "notes/b.md", HASH_A, HASH_A),
        "revision": REVISION,
    },
    "loci/documents/move/preview": {
        "command": "documents/move", "refusals": [],
        "changes": [{"kind": "move", "path": "notes/a.md", "destination": "notes/b.md"}],
    },
    # A real vault reports MANY diagnostic kinds with large counts (the reference
    # vault: 10 kinds, unmanaged=4631). One kind with count 2 never exercised the
    # summary rendering (004 F-08).
    "loci/maintenance/refresh": {
        "revision": REVISION_2, "consistency": "current", "changed_sources": 1,
        "diagnostics_summary": [
            ["unmanaged", 4631], ["missing_target", 412], ["duplicate_top_level_property", 63],
            ["noncanonical_loci_metadata", 48], ["yaml_parse_error", 43],
            ["unterminated_frontmatter", 43], ["degraded_identity", 41],
            ["unknown_loci_key", 21], ["malformed_loci_id", 16], ["unsupported_loci_schema", 13],
        ],
    },
    # The engine returns the RESOLVED TARGET NAME, not the raw wikilink syntax:
    # broken_links[1] and backlinks[2] are bare names ("Note 4538"), never "[[x]]"
    # (004 F-06). Client code that stripped brackets would be writing against a
    # fiction the old fixtures validated.
    "loci/graph/broken_links": {"rows": [["notes/a.md", "Note 4538", "wikilink"]]},
    "loci/graph/missing_attachments": {"rows": [["notes/a.md", "img.png"]]},
    "loci/graph/ambiguous_links": {"rows": []},
    "loci/graph/orphans": {"rows": ["notes/a.md"]},
    "loci/graph/backlinks": {"rows": [["notes/b.md", "wikilink", "Note A"]]},
    "loci/graph/neighbors": {"rows": ["notes/b.md", "notes/c.md"]},
    "loci/graph/project_members": {"rows": [["notes/b.md", "note", "Note B"]]},
    "loci/graph/traversal": {"rows": [["notes/a.md", 0], ["notes/b.md", 1], ["notes/c.md", 1]]},
    # Real snippets are raw document text and CONTAIN EMBEDDED NEWLINES — a
    # single-line "...snippet..." hid the fact that rendering results[4] verbatim
    # would break picker rows (004 F-05).
    "loci/search/text": {
        "results": [[
            "notes/a.md", _uuid_for("notes/a.md"), "managed", "Note A",
            "# Note A\n\nNote A body. See [[Note B]].\n", -2.7062756914445156,
        ]]
    },
    # The host adds `uri` to `command.arguments[0]` (apps/lsp/server.py:182-194) —
    # it is how the client targets the right buffer without re-deriving it. The
    # fake omitted it, so `a.uri or vim.uri_from_bufnr(bufnr)` was only ever
    # exercised on its fallback branch. `expected_hash` is a 64-char content hash,
    # not "abc" (005).
    # `loci.action.execute` — the ONE workspace/executeCommand. `commit` is a
    # STRING, not a SourceCommit object: the adapter projects
    # `result.commit.status.value` (apps/lsp/adapter.py:252-255). This lived
    # inline in the handler, where the validator could only mirror it — and a
    # mirror is a fixture that can drift. Both read this entry now (005).
    "workspace/executeCommand:loci.action.execute": {"applied": True, "commit": "source_committed"},
    # `loci/saveResult` after a committed didSave. A REFUSED save drops
    # `revision` (see handle_notification) — `save_result_optional_keys` records
    # which keys are outcome-dependent. Same reason as above: one definition,
    # read by the handler and by the validator.
    "loci/saveResult": {"committed": True, "reason": "ok", "revision": REVISION},
    "textDocument/codeAction": [
        {
            "title": "Set status: active", "kind": "quickfix",
            "data": {"action_id": "documents.set_status", "path": "notes/a.md",
                     "expected_hash": HASH_A, "args": ["active"]},
            "command": {"title": "Set status: active", "command": "loci.action.execute",
                        "arguments": [{"uri": "file:///vault/notes/a.md",
                                       "action_id": "documents.set_status", "path": "notes/a.md",
                                       "expected_hash": HASH_A, "args": ["active"]}]},
        }
    ],
}


# ---- contract validation (004 R1/R2) ----------------------------------------

CONTRACT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures.json")


def _validate_defaults():
    """Check DEFAULTS against the engine contract in fixtures.json; die loudly on drift.

    This is the mechanism behind the 004 R6 rule. The rule existed informally before
    and was violated thirteen times, because nothing enforced it: a fixture could
    invent a value (`identity_state: "ok"`), shrink one (a 2-char revision), or drop
    a field (`saveResult.uri`) and every test still passed. Now the fake refuses to
    start, so drift surfaces as a hard failure in every scenario at once instead of
    as a bug that reaches a real vault.
    """
    import re

    with open(CONTRACT_PATH) as fh:
        contract = json.load(fh)

    enums = contract["enums"]
    id_re = re.compile(contract["id_pattern"])
    rev_len = contract["revision_length"]
    doc_keys = set(contract["document_keys"])
    ws_keys = set(contract["workspace_view_keys"])
    errors = []

    def check_revision(where, value):
        if isinstance(value, str) and len(value) != rev_len:
            errors.append(f"{where}: revision is {len(value)} chars, engine sends {rev_len}")

    def check_document(where, doc):
        if not isinstance(doc, dict):
            return
        if set(doc) != doc_keys:
            errors.append(f"{where}: document keys {sorted(set(doc))} != engine {sorted(doc_keys)}")
            return
        if not id_re.match(str(doc["id"])):
            errors.append(f"{where}: id {doc['id']!r} is not a UUID (engine sends UUIDs)")
        for field in ("identity_state", "kind", "status", "state"):
            if doc[field] not in enums[field]:
                errors.append(
                    f"{where}: {field}={doc[field]!r} is not in the engine vocabulary {enums[field]}"
                )

    def check_workspace(where, view):
        if isinstance(view, dict) and set(view) != ws_keys:
            errors.append(f"{where}: workspace keys {sorted(set(view))} != engine {sorted(ws_keys)}")

    shape_of = {"document": check_document, "workspace_view": check_workspace}

    for wire, spec in contract["wires"].items():
        if wire not in DEFAULTS:
            continue
        value = DEFAULTS[wire]
        if set(value) != set(spec["keys"]):
            errors.append(f"{wire}: keys {sorted(set(value))} != engine {sorted(spec['keys'])}")
            continue
        for key, shape in (spec.get("rows_of") or {}).items():
            for i, row in enumerate(value.get(key) or []):
                shape_of[shape](f"{wire}.{key}[{i}]", row)
        for key, shape in (spec.get("object_of") or {}).items():
            shape_of[shape](f"{wire}.{key}", value.get(key))
        for key, arity in (spec.get("row_arity") or {}).items():
            for i, row in enumerate(value.get(key) or []):
                if not isinstance(row, list) or len(row) != arity:
                    errors.append(f"{wire}.{key}[{i}]: arity {len(row)} != engine {arity}")
        for key in spec.get("row_scalar") or []:
            for i, row in enumerate(value.get(key) or []):
                if isinstance(row, (list, dict)):
                    errors.append(f"{wire}.{key}[{i}]: engine sends flat scalars, got {type(row).__name__}")
        for field in ("revision", "_revision"):
            if field in value:
                check_revision(f"{wire}.{field}", value[field])
        # `commit.status` is a CommitStatus member (loci-core fs/outcomes.py). This
        # file said "committed", which the engine never emits — the same class of
        # fiction as identity_state "ok", and missed by the 004 audit because that
        # capture used the CLI, whose effect projection hides the SourceCommit.
        commit = value.get("commit")
        if isinstance(commit, dict):
            if commit.get("status") not in enums["commit_status"]:
                errors.append(
                    f"{wire}.commit.status={commit.get('status')!r} is not in the engine "
                    f"vocabulary {enums['commit_status']}"
                )
            # The whole SourceCommit crosses the wire, not just its status (005).
            expected_commit = set(spec.get("commit_keys") or ())
            if expected_commit and set(commit) != expected_commit:
                errors.append(
                    f"{wire}.commit keys {sorted(set(commit))} != engine {sorted(expected_commit)}"
                )
            for field in ("old_hash", "new_hash"):
                if commit.get(field) is not None:
                    check_revision(f"{wire}.commit.{field}", commit[field])

    check_revision("REVISION", REVISION)
    check_revision("REVISION_2", REVISION_2)
    check_revision("HASH_A", HASH_A)
    check_revision("HASH_B", HASH_B)

    # ---- effect surfaces the wire carries OUTSIDE the feature envelope ----------
    #
    # `saveResult`, the code-action rows and the `loci.action.execute` result are
    # all effect shapes, and all three were unvalidated: the 004 audit's ground
    # truth was the CLI, which has no saveResult, no code actions and no
    # executeCommand at all. Their contract now comes from `capture-effects.py`,
    # which probes a live loci-lsp.

    save_required = set(contract.get("save_result_keys") or ())
    save_optional = set(contract.get("save_result_optional_keys") or ())
    save_reasons = set(contract.get("save_result_reasons") or ())
    # `uri` is added per-request by handle_notification; validate the rest.
    default_save = {**DEFAULTS["loci/saveResult"], "uri": ""}
    if save_required and not save_required <= set(default_save):
        errors.append(f"saveResult: missing engine key(s) {sorted(save_required - set(default_save))}")
    stray = set(default_save) - save_required - save_optional
    if save_required and stray:
        errors.append(f"saveResult: key(s) {sorted(stray)} are not in the engine's shape")
    if save_reasons and default_save["reason"] not in save_reasons:
        errors.append(
            f"saveResult.reason={default_save['reason']!r} is not in the engine vocabulary "
            f"{sorted(save_reasons)}"
        )
    check_revision("saveResult.revision", default_save["revision"])

    actions = DEFAULTS.get("textDocument/codeAction") or []
    action_keys = set(contract.get("code_action_keys") or ())
    data_keys = set(contract.get("code_action_data_keys") or ())
    arg_keys = set(contract.get("code_action_command_argument_keys") or ())
    for i, action in enumerate(actions):
        if action_keys and set(action) != action_keys:
            errors.append(f"codeAction[{i}]: keys {sorted(set(action))} != engine {sorted(action_keys)}")
            continue
        if data_keys and set(action["data"]) != data_keys:
            errors.append(
                f"codeAction[{i}].data keys {sorted(set(action['data']))} != engine {sorted(data_keys)}"
            )
        else:
            check_revision(f"codeAction[{i}].data.expected_hash", action["data"]["expected_hash"])
        arg = (action.get("command") or {}).get("arguments", [{}])[0]
        if arg_keys and set(arg) != arg_keys:
            errors.append(
                f"codeAction[{i}].command.arguments[0] keys {sorted(set(arg))} != engine {sorted(arg_keys)}"
            )

    # `loci.action.execute` answers `{applied, commit}` with commit a STRING
    # (adapter.execute_action projects `commit.status.value`), or
    # `{applied: False, reason}` for an unknown action.
    exec_value = DEFAULTS["workspace/executeCommand:loci.action.execute"]
    exec_keys = set(contract.get("action_execute_keys") or ())
    if exec_keys and set(exec_value) != exec_keys:
        errors.append(f"loci.action.execute: keys {sorted(set(exec_value))} != engine {sorted(exec_keys)}")
    if contract.get("action_execute_commit_is_object") is False and isinstance(exec_value["commit"], dict):
        errors.append("loci.action.execute.commit is an object; the engine sends the status STRING")
    if exec_value["commit"] not in enums["commit_status"]:
        errors.append(
            f"loci.action.execute.commit={exec_value['commit']!r} is not in the engine "
            f"vocabulary {enums['commit_status']}"
        )

    if errors:
        sys.stderr.write(
            "fs_v2: FIXTURES DRIFTED FROM THE ENGINE CONTRACT (fixtures.json)\n"
            "  Fixtures must share the engine's shape, width, and vocabulary (004 R6).\n"
            "  Re-capture reads with ./capture-fixtures.sh <vault> --write-contract,\n"
            "  effects with ./capture-effects.py --write-contract, or fix the fixture.\n\n"
            + "".join(f"  - {e}\n" for e in errors)
        )
        sys.exit(2)


_validate_defaults()


def feature_value(method, params):
    if method in _overrides:
        return _overrides[method]
    if method in DEFAULTS:
        value = _env(method, DEFAULTS[method])
        if isinstance(value, dict):
            # workspaces/put (and its preview) accepts full `files`/`documents`
            # lists (the engine's manifest is wholly-owned: a PUT replaces the
            # composition, so the client read-modify-writes). Echo the params so
            # the link-file round trip is assertable.
            if method in ("loci/workspaces/put", "loci/workspaces/put/preview"):
                for key in ("files", "documents"):
                    if params.get(key):
                        value[key] = params[key]
            # move/adopt previews plan against the REQUEST's paths (the real
            # engine's preview_move/preview_adopt echo request.source/destination
            # and request.path), so echo them instead of the static fixture.
            if method == "loci/documents/move/preview":
                value["changes"] = [{"kind": "move", "path": params.get("source") or "notes/a.md",
                                     "destination": params.get("destination") or "notes/b.md"}]
            if method == "loci/documents/adopt/preview":
                value["changes"] = [{"kind": "patch", "path": params.get("path") or "notes/a.md",
                                     "before_excerpt": "", "after_excerpt": "loci: id-a"}]
        return value
    return {}


def handle_notification(msg):
    method = msg["method"]
    params = msg.get("params") or {}
    log("notify " + method + " " + json.dumps(params))
    if method == "textDocument/didOpen":
        if _diags:
            send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                  "params": {"uri": params["textDocument"]["uri"], "diagnostics": _diags}})
        return
    if method == "textDocument/didSave":
        # A committed save carries `revision`; a refused one does NOT (the adapter
        # returns `{committed: False, reason}` and the host only adds `uri` +
        # a default `reason`). The fake padded every outcome with a revision, so a
        # client reading `result.revision` after a conflict would find one under
        # test and nothing on the real server (005). `save_result_optional_keys`
        # in fixtures.json records the split.
        result = dict(DEFAULTS["loci/saveResult"])
        if "save" in _overrides:
            result = _overrides["save"]
            if result.get("committed") is False:
                result.pop("revision", None)
        # The engine sends `{uri, **result}` (apps/lsp/server.py:146) — the uri is
        # how a client attributes a CAS conflict to the buffer that caused it. The
        # fake used to drop it, which removed per-buffer attribution from the
        # design space: no test could tell "we chose not to" from "we cannot"
        # (004 F-03).
        uri = (params.get("textDocument") or {}).get("uri")
        payload = {"uri": uri, **result}
        send({"jsonrpc": "2.0", "method": "loci/saveResult", "params": payload})
        log("save " + json.dumps(payload))
        return


def handle_request(msg):
    method = msg["method"]
    params = msg.get("params") or {}
    log("req " + method + " " + json.dumps(params))
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {
            "capabilities": {
                "textDocumentSync": {"openClose": True, "change": 1, "save": True},
                "diagnosticProvider": {"interFileDependencies": False, "workspaceDiagnostics": False},
            }
        }})
        return
    if method in ("textDocument/didChange", "textDocument/didClose", "$/setTrace"):
        return  # notification
    if method == "workspace/executeCommand":
        cmd = params.get("command")
        if cmd == "loci.test.crash":
            sys.exit(3)
        if cmd == "loci.action.execute":
            # `commit` here is a STRING, not a SourceCommit object: the adapter
            # projects `result.commit.status.value` (apps/lsp/adapter.py:252-255).
            # The fake sent `{"status": ...}`, so a client that read
            # `value.commit.status` would work under test and break on the real
            # server — the F-16 failure mode in a second place (005).
            send({"jsonrpc": "2.0", "id": msg["id"],
                  "result": {"ok": True, "value": DEFAULTS["workspace/executeCommand:loci.action.execute"]}})
            return
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
        return
    if method == "textDocument/codeAction":
        # LSP-standard method: raw ARRAY of actions (no envelope)
        send({"jsonrpc": "2.0", "id": msg["id"], "result": feature_value(method, params)})
        return
    if method == "textDocument/diagnostic":
        # LSP-standard pull diagnostics (nvim pulls when diagnosticProvider is advertised):
        # raw {kind, items} — NOT the feature envelope
        send({"jsonrpc": "2.0", "id": msg["id"],
              "result": {"kind": "full", "items": _diags}})
        return
    # feature methods: loci/<wire> and loci/<wire>/preview
    #
    # DROP mode (004 F-09): a method listed under the "__drop__" override key is
    # never answered. The client must cope with a request that gets no reply --
    # `M.doctor()`'s 4-way barrier used to hang forever and render nothing, and no
    # test could reach it because this fake always answered everything.
    if method in (_overrides.get("__drop__") or []):
        log("drop " + method)
        return
    # REFUSAL mode (004 F-13): `ok` used to be hardcoded True and overrides only
    # substituted `value`, so a server refusal was INEXPRESSIBLE and the whole
    # typed-error surface was untestable hermetically. An override carrying an
    # "ok" key is now sent as the complete envelope.
    override = _overrides.get(method)
    if isinstance(override, dict) and "ok" in override:
        send({"jsonrpc": "2.0", "id": msg["id"], "result": override})
        return
    value = feature_value(method, params)
    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})


while True:
    msg = read_msg()
    if "id" not in msg:
        if msg.get("method") == "exit":  # graceful LSP shutdown: exit now (nvim keeps stdin open)
            sys.exit(0)
        handle_notification(msg)
        continue
    handle_request(msg)
