#!/usr/bin/env python3
"""capture-effects.py — ground truth for EFFECT envelopes, taken from the live LSP.

`capture-fixtures.sh` covers READS only, and says so. For a read the CLI envelope
IS the wire envelope, so the CLI is an honest source. For an EFFECT it is not:

  * the CLI projects a `CommandPreview`  -> `{command, changes, refusals, _committed}`
  * the LSP host sends the `SourceCommit` -> `{document, commit: {...}, revision}`

Project 004 captured effects from the CLI and validated the fake against a shape
the client never sees. Two live bugs (F-14, F-15) and one invented enum value
(F-16 `commit.status: "committed"`) came straight out of that blind spot. This
script closes it: it speaks raw JSON-RPC to a real `loci-lsp`, drives every
mutating wire plus the save lifecycle against a THROWAWAY vault, and prints the
envelopes the client actually receives.

Usage:
  ./capture-effects.py                     # scratch vault, dump every envelope
  ./capture-effects.py --vault <root>      # use an existing vault (it WILL be written to)
  ./capture-effects.py --write-contract    # merge the observed shapes into fixtures.json

`--write-contract` records the same machine-checkable contract the read capture
does — key sets, enum vocabularies, widths — for the effect wires and for the
`loci/saveResult` notification, the `loci.action.execute` result and the
`textDocument/codeAction` rows. `fs_v2.py` validates its DEFAULTS against it at
startup, so an effect fixture can no longer drift unnoticed.

Requires `loci` and `loci-lsp` on PATH (nix: `nix shell .#loci-lsp`).
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
CONTRACT = HERE / "fixtures.json"
TIMEOUT = 30.0


# ----------------------------------------------------------------- transport


class Server:
    """A raw JSON-RPC conversation with one `loci-lsp` process."""

    def __init__(self, root: Path) -> None:
        self.proc = subprocess.Popen(
            ["loci-lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.inbox: queue.Queue = queue.Queue()
        self.notifications: list[dict] = []
        self.stderr: list[str] = []
        threading.Thread(target=self._drain_out, daemon=True).start()
        threading.Thread(target=self._drain_err, daemon=True).start()
        self._id = 0
        self.request("initialize", {"processId": os.getpid(), "rootUri": uri_of(root), "capabilities": {}})
        self.notify("initialized", {})

    def _drain_err(self) -> None:
        for line in self.proc.stderr:
            self.stderr.append(line.decode("utf-8", "replace").rstrip())

    def _drain_out(self) -> None:
        stream = self.proc.stdout
        while True:
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                ch = stream.read(1)
                if not ch:
                    return
                header += ch
            length = int(dict(line.split(b": ", 1) for line in header.strip().split(b"\r\n"))[b"Content-Length"])
            self.inbox.put(json.loads(stream.read(length)))

    def _send(self, msg: dict) -> None:
        body = json.dumps(msg).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def notify(self, method: str, params: dict) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method: str, params: dict, timeout: float = TIMEOUT):
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.inbox.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("id") == rid:
                return msg.get("result", {"__error__": msg.get("error")})
            if "method" in msg:
                self.notifications.append(msg)
        return {"__no_reply__": True, "method": method}

    def sync(self) -> None:
        """Barrier: notifications are queued, so a bare `notify` has NOT been
        processed when the call returns. Without this the capture races itself —
        writing a file right after sending didOpen let the server read the NEW
        bytes as the CAS base, and the conflict probes came back `committed`."""
        self.request("loci/workspaces/list", {})

    def drain_notifications(self, settle: float = 0.6) -> None:
        deadline = time.time() + settle
        while time.time() < deadline:
            try:
                msg = self.inbox.get(timeout=max(0.05, deadline - time.time()))
            except queue.Empty:
                return
            if "method" in msg:
                self.notifications.append(msg)

    def close(self) -> None:
        self.proc.kill()


def uri_of(path) -> str:
    return "file://" + quote(str(path))


# ------------------------------------------------------------- scratch vault


def build_scratch_vault(root: Path) -> None:
    """A vault small enough to reason about and rich enough to exercise every verb.

    Only `loci init` and plain files here. The CLI's mutating verbs do NOT commit
    — `loci --json documents/create` returns a CommandPreview with
    `_committed: false` — so the project document this capture needs is created
    over the wire, inside `capture()`, like every other effect.
    """
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["loci", "--vault", str(root), "init"], check=True, capture_output=True)
    (root / "notes").mkdir(exist_ok=True)
    (root / "notes/plain.md").write_text("# Plain\n\nAn unmanaged note. See [[Missing Target]].\n")
    (root / "notes/member.md").write_text("# Member\n\nA note that will join a project.\n")
    (root / "notes/occupied.md").write_text("# Occupied\n\nA destination that already exists.\n")


# ------------------------------------------------------------------ the run


def capture(root: Path) -> dict:
    """Drive every effect surface and return {label: envelope}."""
    srv = Server(root)
    out: dict = {}

    def feature(wire: str, params: dict, label: str | None = None) -> dict:
        env = srv.request(f"loci/{wire}", params)
        out[label or f"loci/{wire}"] = env
        return env

    # The project document the relations wires need. Created over the wire
    # because only the LSP route commits (the CLI previews).
    srv.request("loci/documents/create", {"name": "Proj", "kind": "project"})
    srv.request("loci/maintenance/refresh", {})

    # ---- mutating features: the committing route AND its pure preview ------
    feature("documents/create/preview", {"name": "Captured"})
    feature("documents/create", {"name": "Captured", "kind": "task", "body": "# Captured\n"})
    # refused: the same name twice -> precondition_failed / destination_exists
    feature("documents/create", {"name": "Captured"}, label="loci/documents/create REFUSED")
    feature("documents/create/preview", {"name": "Captured"}, label="loci/documents/create/preview REFUSED")

    feature("documents/adopt/preview", {"path": "notes/plain.md"})
    feature("documents/adopt", {"path": "notes/plain.md"})
    feature("documents/adopt", {"path": "notes/nonexistent.md"}, label="loci/documents/adopt REFUSED")

    feature("documents/format_owned/preview", {"ref": "notes/plain.md"})
    feature("documents/format_owned", {"ref": "notes/plain.md"})

    feature("documents/set_status/preview", {"ref": "notes/plain.md", "status": "active"})
    feature("documents/set_status", {"ref": "notes/plain.md", "status": "active"})
    feature(
        "documents/set_status",
        {"ref": "notes/plain.md", "status": "not: a scalar"},
        label="loci/documents/set_status REFUSED",
    )

    feature("documents/preview_adoption", {"path": "notes/member.md"})

    feature("relations/add_project/preview", {"document": "notes/member.md", "project": "Proj.md"})
    feature("relations/add_project", {"document": "notes/member.md", "project": "Proj.md"})
    feature("relations/remove_project/preview", {"document": "notes/member.md", "project": "Proj.md"})
    feature("relations/remove_project", {"document": "notes/member.md", "project": "Proj.md"})

    feature("documents/move/preview", {"source": "notes/plain.md", "destination": "notes/moved.md"})
    feature("documents/move", {"source": "notes/plain.md", "destination": "notes/moved.md"})
    feature(
        "documents/move",
        {"source": "notes/moved.md", "destination": "notes/occupied.md"},
        label="loci/documents/move REFUSED",
    )

    feature("workspaces/put/preview", {"name": "WSCap"})
    put = feature("workspaces/put", {"name": "WSCap"})
    wid = ((put.get("value") or {}).get("workspace_id")) if isinstance(put, dict) else None
    if wid:
        feature(
            "workspaces/put",
            {"workspace_id": wid, "name": "WSCap", "files": [{"path": "notes/occupied.md", "role": "reference"}]},
            label="loci/workspaces/put (update, with members)",
        )
        feature("workspaces/archive/preview", {"workspace_id": wid, "archived": True})
        feature("workspaces/archive", {"workspace_id": wid, "archived": True})

    # ---- the save lifecycle: every branch of adapter.did_save -------------
    def save_probe(label: str, rel: str, setup, buffer_text: str) -> None:
        target = root / rel
        setup(target)
        text = target.read_text() if target.exists() else ""
        doc_uri = uri_of(target)
        srv.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": doc_uri, "languageId": "markdown", "version": 1, "text": text}},
        )
        srv.sync()
        srv.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": doc_uri, "version": 2}, "contentChanges": [{"text": buffer_text}]},
        )
        srv.sync()
        before = len(srv.notifications)
        srv.notify("textDocument/didSave", {"textDocument": {"uri": doc_uri}})
        srv.drain_notifications(1.5)
        for msg in srv.notifications[before:]:
            if msg.get("method") == "loci/saveResult":
                out[f"loci/saveResult {label}"] = msg["params"]
                break
        srv.notify("textDocument/didClose", {"textDocument": {"uri": doc_uri}})

    save_probe("committed", "notes/save-a.md", lambda p: p.write_text("# A\n"), "# A\n\nedited\n")
    save_probe("unchanged", "notes/save-b.md", lambda p: p.write_text("# B\n"), "# B\n")

    def diverge(p: Path) -> None:
        p.write_text("# C\n")

    target = root / "notes/save-c.md"
    diverge(target)
    doc_uri = uri_of(target)
    srv.notify(
        "textDocument/didOpen",
        {"textDocument": {"uri": doc_uri, "languageId": "markdown", "version": 1, "text": "# C\n"}},
    )
    srv.sync()  # the base hash is recorded HERE — write the disk only after it lands
    srv.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc_uri, "version": 2}, "contentChanges": [{"text": "# C\n\nbuffer edit\n"}]},
    )
    srv.sync()
    target.write_text("# C\n\nDISK MOVED ON\n")  # the CAS base is now stale
    before = len(srv.notifications)
    srv.notify("textDocument/didSave", {"textDocument": {"uri": doc_uri}})
    srv.drain_notifications(1.5)
    for msg in srv.notifications[before:]:
        if msg.get("method") == "loci/saveResult":
            out["loci/saveResult source_hash_mismatch"] = msg["params"]
            break

    # a document the server never opened, and one neovim itself just created
    before = len(srv.notifications)
    srv.notify("textDocument/didSave", {"textDocument": {"uri": uri_of(root / "notes/never-opened.md")}})
    srv.drain_notifications(1.5)
    for msg in srv.notifications[before:]:
        if msg.get("method") == "loci/saveResult":
            out["loci/saveResult not_open"] = msg["params"]
            break

    fresh = root / "notes/fresh.md"
    fresh.unlink(missing_ok=True)
    fresh_uri = uri_of(fresh)
    srv.notify(
        "textDocument/didOpen",
        {"textDocument": {"uri": fresh_uri, "languageId": "markdown", "version": 1, "text": ""}},
    )
    srv.sync()  # the file must still be ABSENT when didOpen lands (base_hash = None)
    srv.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": fresh_uri, "version": 2}, "contentChanges": [{"text": "# Fresh\n"}]},
    )
    srv.sync()
    fresh.write_text("# Fresh\n")  # neovim writes the file BEFORE it sends didSave
    before = len(srv.notifications)
    srv.notify("textDocument/didSave", {"textDocument": {"uri": fresh_uri}})
    srv.drain_notifications(1.5)
    for msg in srv.notifications[before:]:
        if msg.get("method") == "loci/saveResult":
            out["loci/saveResult new-file (:w on BufNewFile)"] = msg["params"]
            break

    # ---- code actions + the ONE executeCommand ---------------------------
    action_target = root / "notes/occupied.md"
    action_uri = uri_of(action_target)
    srv.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": action_uri, "languageId": "markdown", "version": 1,
                "text": action_target.read_text(),
            }
        },
    )
    actions = srv.request(
        "textDocument/codeAction",
        {
            "textDocument": {"uri": action_uri},
            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
            "context": {"diagnostics": []},
        },
    )
    out["textDocument/codeAction"] = actions
    if isinstance(actions, list) and actions:
        arg = dict(actions[0]["command"]["arguments"][0])
        out["workspace/executeCommand loci.action.execute"] = srv.request(
            "workspace/executeCommand",
            {"command": "loci.action.execute", "arguments": [{"uri": action_uri, "action": arg, **arg}]},
        )
    out["workspace/executeCommand unknown action"] = srv.request(
        "workspace/executeCommand",
        {
            "command": "loci.action.execute",
            "arguments": [{"uri": action_uri, "action_id": "documents.nope", "path": "notes/occupied.md",
                           "expected_hash": "", "args": []}],
        },
    )

    srv.close()
    return out


# --------------------------------------------------------------- contract IO


def merge_contract(observed: dict) -> list[str]:
    """Record the observed effect shapes in fixtures.json. Returns a change log."""
    with CONTRACT.open() as fh:
        contract = json.load(fh)
    wires = dict(contract["wires"])
    enums = {k: list(v) for k, v in contract["enums"].items()}
    changes: list[str] = []

    for label, env in observed.items():
        if not label.startswith("loci/") or " " in label or not isinstance(env, dict):
            continue
        if not env.get("ok"):
            continue
        value = {k: v for k, v in (env.get("value") or {}).items() if not k.startswith("_")}
        if not value:
            continue
        spec = dict(wires.get(label, {}))
        keys = sorted(value)
        if spec.get("keys") != keys:
            changes.append(f"{label}: keys {spec.get('keys')} -> {keys}")
        spec["keys"] = keys
        commit = value.get("commit")
        if isinstance(commit, dict):
            spec["commit_keys"] = sorted(commit)
            if commit.get("status") not in enums["commit_status"]:
                enums["commit_status"].append(commit["status"])
        wires[label] = spec

    # saveResult: the key set is NOT uniform — a committed save carries `revision`, a refused one
    # does not. Record required (present in every outcome) and optional separately, so the fake
    # cannot pad a failure with a field the engine omits.
    every: set[str] | None = None
    any_key: set[str] = set()
    reasons: list[str] = []
    for label, params in observed.items():
        if not label.startswith("loci/saveResult") or not isinstance(params, dict):
            continue
        keys = set(params)
        every = keys if every is None else (every & keys)
        any_key |= keys
        reason = params.get("reason")
        if reason and reason not in reasons:
            reasons.append(reason)
    if every is not None:
        contract["save_result_keys"] = sorted(every)
        contract["save_result_optional_keys"] = sorted(any_key - every)
        contract["save_result_reasons"] = sorted(set(reasons) | set(contract.get("save_result_reasons") or []))
        changes.append(
            f"saveResult: required {sorted(every)} optional {sorted(any_key - every)} "
            f"reasons {contract['save_result_reasons']}"
        )

    actions = observed.get("textDocument/codeAction")
    if isinstance(actions, list) and actions:
        contract["code_action_keys"] = sorted(actions[0])
        contract["code_action_data_keys"] = sorted(actions[0].get("data") or {})
        contract["code_action_command_argument_keys"] = sorted(actions[0]["command"]["arguments"][0])
        changes.append(f"codeAction: keys {contract['code_action_keys']}")

    exec_env = observed.get("workspace/executeCommand loci.action.execute")
    if isinstance(exec_env, dict) and exec_env.get("ok"):
        value = exec_env.get("value") or {}
        contract["action_execute_keys"] = sorted(value)
        contract["action_execute_commit_is_object"] = isinstance(value.get("commit"), dict)
        changes.append(
            f"loci.action.execute: keys {contract['action_execute_keys']} "
            f"commit_is_object={contract['action_execute_commit_is_object']}"
        )

    contract["enums"] = enums
    contract["wires"] = wires
    with CONTRACT.open("w") as fh:
        json.dump(contract, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    return changes


def main() -> int:
    args = sys.argv[1:]
    write = "--write-contract" in args
    vault = None
    if "--vault" in args:
        vault = Path(args[args.index("--vault") + 1]).resolve()
    for binary in ("loci", "loci-lsp"):
        if shutil.which(binary) is None:
            print(f"error: `{binary}` is not on PATH — try: nix shell .#loci-lsp", file=sys.stderr)
            return 2

    tmp = None
    if vault is None:
        tmp = Path(tempfile.mkdtemp(prefix="loci-effects-"))
        vault = tmp / "vault"
        build_scratch_vault(vault)
    try:
        observed = capture(vault)
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)

    print("# effect ground truth — captured from the LIVE loci-lsp (NOT the CLI)")
    print(f"# vault: {vault}")
    print()
    for label, env in observed.items():
        print(f"### {label}")
        print(json.dumps(env, indent=2, default=str)[:2400])
        print()

    if write:
        for line in merge_contract(observed):
            print(f"contract: {line}", file=sys.stderr)
        print(f"contract updated: {CONTRACT}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
