#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: read hubs. `loci/op` `project.index` returns a single project row
(the row's `content_path` is what the hub opens), `workspace.index` returns one
workspace. Everything else -> `{ok: true, value: {}}`. Used by the root-anchoring
(F1), mid-flow-switch (F3), single-vault, and server-death (F9) tests.
"""
import json
import sys

# optional LOG: when given, every loci/op read and workspace/executeCommand is
# logged (command/op name + args) so tests can assert what reached the server.
LOG = sys.argv[1] if len(sys.argv) > 1 else None


def log(line):
    if LOG:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def read_msg():
    headers = b""
    while b"\r\n\r\n" not in headers:
        chunk = sys.stdin.buffer.read(1)
        if not chunk:  # stdin closed (graceful LSP shutdown) -> exit cleanly
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


def write_msg(obj):
    payload = json.dumps(obj).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
    sys.stdout.buffer.flush()


while True:
    msg = read_msg()
    if "id" not in msg:
        if msg.get("method") == "exit":  # graceful LSP shutdown: exit now (nvim keeps stdin open)
            sys.exit(0)
        continue
    m = msg["method"]
    params = msg.get("params") or {}
    if m == "initialize":
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}}})
    elif m == "workspace/executeCommand":
        # abnormal server death for the F9 test: exit nonzero mid-request
        if params.get("command") == "loci.test.crash":
            sys.exit(3)
        log("cmd " + json.dumps(params))
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
    elif m == "loci/op":
        log("op " + params.get("op", "?") + " " + json.dumps(params.get("args") or {}))
        op = params.get("op")
        if op == "project.index":
            value = [
                {
                    "project_id": "p1",
                    "title": "P1",
                    "status": "active",
                    "content_path": "projects/p1.md",
                }
            ]
        elif op == "workspace.index":
            value = [{"workspace_id": "ws-1", "name": "WS1", "archived": False}]
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
