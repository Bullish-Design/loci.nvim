#!/usr/bin/env python3
"""Fake loci-lsp over stdio (Content-Length framing).

Scenario shape: crafted `loci/commands` palette + note/start-work effects. The
palette advertises `loci.note.create` (required `title` string; optional `type`
vocab with EMPTY values; optional `list`; optional string) and `loci.start-work`
(required `title`; optional `project_id`) — the arg shapes the prompt-args and F5
tests need. Effects: note-creating verbs answer with a MarkdownObject
(`content_path`); `loci.start-work` answers with an ActivationPlan whose
`primary_content_path` + `editor_state` come from RESPONSE_FILE (per-test crafted;
defaults to a resession-tab block). Every executeCommand (command + arguments) is
logged to LOG.
"""
import json
import sys

LOG = sys.argv[1]
RESPONSE_FILE = sys.argv[2] if len(sys.argv) > 2 else None


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
    elif m == "loci/commands":
        write_msg(
            {
                "jsonrpc": "2.0",
                "id": msg["id"],
                "result": {
                    "commands": [
                        {
                            "command": "loci.note.create",
                            "title": "note.create",
                            "args": [
                                {"name": "title", "required": True, "kind": "string"},
                                {"name": "type", "required": False, "kind": "vocab", "values": []},
                                {"name": "tags", "required": False, "kind": "list"},
                                {"name": "dir", "required": False, "kind": "string"},
                            ],
                        },
                        {
                            "command": "loci.start-work",
                            "title": "start-work",
                            "args": [
                                {"name": "title", "required": True, "kind": "string"},
                                {"name": "project_id", "required": False, "kind": "string"},
                            ],
                        },
                    ]
                },
            }
        )
    elif m == "workspace/executeCommand":
        cmd = params.get("command")
        args = params.get("arguments")
        with open(LOG, "a") as f:
            f.write(cmd + " " + json.dumps(args) + "\n")
        if cmd in ("loci.note.create", "loci.note.daily", "loci.note.scratch"):
            value = {"content_path": "notes/x.md"}
        elif cmd == "loci.start-work":
            if RESPONSE_FILE:
                with open(RESPONSE_FILE) as f:
                    value = json.load(f)
            else:
                value = {
                    "primary_content_path": "notes/x.md",
                    "editor_state": {"resession": {"session_name": "loci-tab-ws", "scope": "tab"}},
                }
        else:
            value = {}
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": value}})
    else:
        write_msg({"jsonrpc": "2.0", "id": msg["id"], "result": {"ok": True, "value": {}}})
