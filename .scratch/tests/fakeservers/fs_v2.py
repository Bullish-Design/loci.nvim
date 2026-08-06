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

def _doc(path, title=None, kind=None, state="managed"):
    return {
        "path": path, "id": "id-" + path.split("/")[-1], "kind": kind,
        "title": title if title is not None else path.split("/")[-1],
        "status": "active" if kind == "project" else None,
        "state": state, "identity_state": "ok" if state == "managed" else "degraded",
    }


def _env(method, value):
    """Append _revision/_consistency to every feature value (the CLI does this for
    every result — all feature handlers return SnapshotResult)."""
    if isinstance(value, dict):
        out = dict(value)
        out.setdefault("_revision", "r1")
        out.setdefault("_consistency", "current")
        return out
    return value


DEFAULTS = {
    "loci/workspaces/list": {
        "workspaces": [
            {"id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None, "archived": False}
        ]
    },
    "loci/workspaces/get": {
        "view": {
            "id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None,
            "archived": False, "documents": [], "files": [],
        }
    },
    "loci/workspaces/put": {
        "workspace_id": "ws-2", "path": ".loci/workspaces/ws2.yaml", "commits": [],
        "adopted_members": [], "revision": "r1",
    },
    "loci/workspaces/archive": {
        "view": {"id": "ws-1", "name": "WS1", "path": ".loci/workspaces/ws1.yaml", "project": None,
                 "archived": True, "documents": [], "files": []},
        "commit": {"status": "committed"}, "revision": "r1",
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
    "loci/documents/list": {
        "documents": [
            _doc("projects/p1.md", title="P1", kind="project"),
            _doc("notes/a.md", title="Note A", kind=None),
        ]
    },
    "loci/documents/get": {"document": _doc("projects/p1.md", title="P1", kind="project")},
    "loci/documents/create": {
        "document": _doc("notes/x.md", title="x", kind=None),
        "commit": {"status": "committed"}, "revision": "r1",
    },
    "loci/documents/adopt": {
        "document": _doc("notes/a.md", title="a"),
        "commit": {"status": "committed"}, "revision": "r1",
    },
    "loci/documents/adopt/preview": {
        "command": "documents/adopt", "refusals": [],
        "changes": [{"kind": "patch", "path": "notes/a.md",
                     "before_excerpt": "", "after_excerpt": "loci: id-a"}],
    },
    "loci/documents/move": {
        "document": _doc("notes/b.md", title="b"),
        "commit": {"status": "committed"}, "revision": "r1",
    },
    "loci/documents/move/preview": {
        "command": "documents/move", "refusals": [],
        "changes": [{"kind": "move", "path": "notes/a.md", "destination": "notes/b.md"}],
    },
    "loci/maintenance/refresh": {
        "revision": "r2", "consistency": "current", "changed_sources": 1,
        "diagnostics_summary": [["unmanaged", 2]],
    },
    "loci/graph/broken_links": {"rows": [["notes/a.md", "[[missing]]", "wikilink"]]},
    "loci/graph/missing_attachments": {"rows": [["notes/a.md", "![[img.png]]"]]},
    "loci/graph/ambiguous_links": {"rows": []},
    "loci/graph/orphans": {"rows": ["notes/a.md"]},
    "loci/graph/backlinks": {"rows": [["notes/b.md", "wikilink", "[[a]]"]]},
    "loci/graph/neighbors": {"rows": ["notes/b.md", "notes/c.md"]},
    "loci/graph/project_members": {"rows": [["notes/b.md", "note", "Note B"]]},
    "loci/graph/traversal": {"rows": [["notes/a.md", 0], ["notes/b.md", 1], ["notes/c.md", 1]]},
    "loci/search/text": {"results": [["notes/a.md", "id-a", "managed", "Note A", "...snippet...", -1.2]]},
    "textDocument/codeAction": [
        {
            "title": "Set status: active", "kind": "quickfix",
            "data": {"action_id": "documents.set_status", "path": "notes/a.md",
                     "expected_hash": "abc", "args": ["active"]},
            "command": {"title": "Set status: active", "command": "loci.action.execute",
                        "arguments": [{"action_id": "documents.set_status", "path": "notes/a.md",
                                       "expected_hash": "abc", "args": ["active"]}]},
        }
    ],
}


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
        result = {"committed": True, "reason": "ok", "revision": "r1"}
        if "save" in _overrides:
            result = _overrides["save"]
        send({"jsonrpc": "2.0", "method": "loci/saveResult", "params": dict(result)})
        log("save " + json.dumps(result))
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
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {"applied": True, "commit": {"status": "committed"}}}})
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
