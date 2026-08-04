#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: doctor report. `loci/op` `doctor` returns a report with one
`missing_loci_id` finding (fixable via `loci.doctor_fix`). Every
`workspace/executeCommand` is logged (command only) to LOG and answered ok.
Used by the pinned-checktime and F7 unsaved-buffer-warning tests.
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
        if op == "doctor":
            value = {
                "ok": False,
                "issues": [
                    {
                        "code": "missing_loci_id",
                        "message": "missing id",
                        "severity": "warning",
                        "path": "notes/a.md",
                    }
                ],
                "stats": {"by_code": {"missing_loci_id": 1}, "scanned": 1},
            }
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    elif m == "workspace/executeCommand":
        cmd = params.get("command")
        with open(LOG, "a") as f:
            f.write(cmd + "\n")
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
