#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: status-hub reads + deactivate plan + command logging. Serves the
`workspace.current`/`workspace.summary`/`workspace.get` reads the status hub needs,
logs every `workspace/executeCommand` (command + arguments) to LOG, and answers
`loci.workspace.deactivate` with the engine's DeactivationPlan
(`{workspace_id, save_session, save_wayfinder}`). Used by the deactivate tests
(F2/F4/F8).
"""
import json
import sys

LOG = sys.argv[1]


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
    elif m == "loci/op":
        op = params.get("op")
        if op == "workspace.current":
            value = {"found": True, "workspace_id": "ws-1", "project_id": None}
        elif op == "workspace.summary":
            value = {
                "workspace_id": "ws-1",
                "name": "WS1",
                "knowledge_count": 0,
                "linked_file_count": 0,
                "is_archived": False,
            }
        elif op == "workspace.get":
            value = {
                "workspace_id": "ws-1",
                "name": "WS1",
                "knowledge": {"primary_loci_id": None, "objects": []},
                "linked_files": [],
            }
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    elif m == "workspace/executeCommand":
        cmd = params.get("command")
        args = params.get("arguments")
        with open(LOG, "a") as f:
            f.write(cmd + " " + json.dumps(args) + "\n")
        if cmd == "loci.workspace.deactivate":
            value = {"workspace_id": "ws-1", "save_session": True, "save_wayfinder": True}
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
