# Obsidian boundary

Loci documents are **ordinary markdown at their real vault-relative paths** (arch §6.1) — there
is no `.loci/content/` knowledge jail anymore. Daily notes, scratch notes, project documents, and
adopted notes are files you can open in Obsidian, ripgrep, or any other tool, exactly where they
are.

What loci owns is the canonical `loci:` region inside a document's frontmatter (schema, id,
projects) plus the shared `status` property when a code action asks to change it — everything
else in the file is preserved byte-for-byte (arch §2.2).

## Wiring it into Obsidian

> **The client never creates or manages symlinks.** No `:LociInit`, no `.loci/loci.json` vault
> block, no auto-symlinking. That was removed in the earlier rewrite and stays removed.

Point Obsidian at the vault root itself (it's a normal vault), or symlink whatever subtrees you
want to browse:

```bash
ln -s /path/to/repo/notes ~/Documents/Notes/projects/my-repo
```

Obsidian integration in this Neovim config (the `<leader>n` group,
`lua/productivity/obsidian.lua`) is independent of loci and configured there, not by loci.
