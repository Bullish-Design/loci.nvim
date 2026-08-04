#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: slow initialize. The `initialize` RESPONSE is delayed by DELAY_MS
(default 3000) so the client stays in its "server still starting" window long
enough for the latency-notice test to fire a read. After initialize, everything
else -> `{ok: true, value: {}}`.
"""
import json
import sys
import time

DELAY_MS = int(sys.argv[1]) if len(sys.argv) > 1 else 3000


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
    if m == "initialize":
        time.sleep(DELAY_MS / 1000.0)
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
