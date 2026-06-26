# Troubleshooting

Start with the vault health hub: `<leader>ld` (`:LociDoctor`) lists the engine's findings for the vault and
offers a one-shot **"Fix all missing loci_id"**.

## The client isn't doing anything

Almost always **PATH**. If `loci-lsp` isn't on Neovim's PATH, `vim.lsp.start` silently no-ops — no attach, no
error.

```bash
which loci-lsp && loci-lsp --help; echo "exit=$?"   # run OUTSIDE the devenv shell
```

If that fails, reinstall and confirm `~/.local/bin` is on PATH:

```bash
uv tool install --from ~/Documents/Projects/loci-core/lsp loci-lsp
```

Then in the editor, on a file under the vault:

```vim
:lua =vim.lsp.get_clients({ name = 'loci' })[1] ~= nil   " -> true
:LspLog                                                  " inspect attach errors
```

## "open a file inside a loci vault"

Reads and effects need the current buffer attached to the loci client — i.e. a file beneath a `.loci/`
directory. Open a vault file first.

## A code action applied but the buffer looks unchanged

The engine wrote the file (it's the sole writer) and the client ran `:checktime` to reload. `:checktime`
won't clobber an **unsaved** buffer — save or `:e` to pick up the change.

## Two completion menus

Shouldn't happen: the client never calls `vim.lsp.completion.enable` — blink's `lsp` source carries loci
completion. If you see a double menu, something else re-enabled native LSP completion.

## The server behaves like an old version

You changed the `loci-core` engine but the installed tool is stale. Refresh:

```bash
uv tool install --force --from ~/Documents/Projects/loci-core/lsp loci-lsp
```

## A finding can't be auto-fixed

Only `missing_loci_id` is auto-fixable today (`doctor_fix`). For other findings, open the file from the doctor
hub and fix it manually, or run **reconcile** from the status hub (`<leader>ls → ▸ reconcile workspace`).
