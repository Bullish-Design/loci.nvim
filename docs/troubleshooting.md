# Troubleshooting

Start with the vault-health hub: `<leader>ld` (`:LociDoctor`) refreshes the index and lists the
engine's graph findings (broken links, missing attachments, ambiguous links, orphans) plus the
per-code diagnostics summary.

## The client isn't doing anything

Almost always **PATH**. If `loci-lsp` isn't on Neovim's PATH, `vim.lsp.start` silently no-ops —
no attach, no error.

```bash
which loci-lsp && loci-lsp --help; echo "exit=$?"   # run OUTSIDE the devenv shell
```

The binary comes from loci-core's flake (this repo re-exports it). Then, on a file under the
vault:

```vim
:lua =vim.lsp.get_clients({ name = 'loci' })[1] ~= nil   " -> true
:LspLog                                                  " inspect attach errors
```

## "vault not initialized (missing .loci/vault.toml)"

The `.loci/` directory exists but the V2 manifest is missing, so `Loci.open` would raise
`VaultNotInitialized`. The client refuses to spawn a doomed server. Run the engine's init verb
(e.g. `loci init`) and reopen a vault file.

## "open a file inside a loci vault"

Reads and effects need the current buffer attached to the loci client — i.e. a file beneath a
`.loci/` directory with a `vault.toml`. Open a vault file first.

## "no workspace pinned in this tab"

V2 has no engine-side "active workspace" — the tab owns the pin. Pick one:
`:LociWorkspaces` (`<leader>lw`).

## "save not committed: …"

Saves are **CAS source commits** (D-041): the server commits only if the bytes on disk still
match the hash captured when you opened the buffer. A concurrent external edit (sync tool, another
editor, the engine itself) between open and save produces `committed: false` — the client warns
instead of silently overwriting. Reload the file (`:e`) and re-apply your edit. An unchanged save
is silent by design.

Your text is never at risk here: neovim writes the file and only then tells the server, so the
bytes are on disk whatever the server answers. The notice is about the **commit**, not the write.

**`destination_exists` on a brand-new note** used to fire on every `:w` of a file created during
the session, forever. That was an engine bug (the exclusive create found the file neovim had just
written) and it is fixed: the engine now adopts those bytes, indexes them, and answers `unchanged`,
which is silent. If you still see `destination_exists`, the file on disk is **not** what your
buffer holds — treat it as the conflict above.

## "…refused: unsupported_new_value" (set_status)

`documents.set_status` refuses values that would not reparse equal (D-027) — e.g. `yes`, `no`,
`123`, `""`, `done #soon`. Use a value that is a plain YAML scalar meaning that string
(`active`, `todo`, `in progress`, …). This is a capability gap on purpose: the engine never
commits bytes whose meaning differs from what you asked.

## "move refused" (LociMove)

The engine plans `documents/move` against the request's `source`/`destination` and surfaces its
refusals as envelope errors (typed notices): `same_path` (source == destination),
`destination_exists` (the target already has a file), `source_missing` (the source isn't there —
reload and retry). The move itself is CAS-protected on the source hash, so a concurrent external
edit between preview and apply makes the engine refuse rather than clobber.

## "is already linked (…)" (LociLinkFile)

`:LociLinkFile` refuses client-side when the current file already has a role in the pinned
workspace's manifest (read-modify-write dedupes before any PUT). Unlink by editing the manifest
(`.loci/workspaces/<id>.yaml` `files:` list) out-of-band — deletion is not a wire capability.

## A code action applied but the buffer looks unchanged

The engine wrote the file (it's the sole writer) and the client ran `:checktime` to reload.
`:checktime` won't clobber an **unsaved** buffer — save or `:e` to pick up the change.

## A link shows `missing_target` / `ambiguous_link`

Those are V2 diagnostics (D-047) with real spans: the target file is gone (or the link is
ambiguous — a case collision or duplicate basename, which resolution refuses to guess about,
D-035). Fix the link; the next refresh clears the diagnostic.

## The server behaves like an old version

You changed the `loci-core` engine but the installed tool is stale. For the flake path, bump the
loci-core pin / nix-nvim input; for manual installs, refresh the `loci-lsp` tool.
