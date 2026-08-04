#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: activation plans. `loci.workspace.activate` answers with the JSON
read from RESPONSE_FILE (the caller per-test crafts the `editor_state` variant:
resession tab/global block, or git first/recorded). Every
`workspace/executeCommand` (command + arguments) is logged to LOG. Used by the
activation-routing (F3-hardening), global-session-guard, and F6 git-observation
tests.
"""
import json
import sys

LOG, RESPONSE_FILE = sys.argv[1], sys.argv[2]


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
        cmd = params.get("command")
        args = params.get("arguments")
        with open(LOG, "a") as f:
            f.write(cmd + " " + json.dumps(args) + "\n")
        if cmd == "loci.workspace.activate":
            with open(RESPONSE_FILE) as f:
                value = json.load(f)
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
