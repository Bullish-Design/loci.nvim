# Obsidian boundary

Loci exposes only `<vault>/.loci/content/` as a knowledge layer. It does **not** expose engine internals,
indexes, or integration state — those stay private to `loci-core`.

`.loci/content/` is plain markdown: daily notes, scratch notes, knowledge notes, and project notes, each with
a `loci_id` in frontmatter. Because it's ordinary markdown, any tool can read it — Obsidian, markdown-oxide,
ripgrep, etc.

## Wiring it into Obsidian

> **Changed in the rewrite.** The old monolith auto-managed an Obsidian symlink via `:LociInit` and a
> `.loci/loci.json` `vault` block. That is **gone** — the client no longer creates or manages symlinks.

To browse a vault's notes in Obsidian, point Obsidian at `.loci/content/` yourself — either open it as a vault
directly, or symlink it under an existing Obsidian vault, for example:

```bash
ln -s /path/to/repo/.loci/content ~/Documents/Notes/projects/my-repo
```

Obsidian integration in this Neovim config (the `<leader>n` group, `lua/productivity/obsidian.lua`) is
independent of loci and is configured there, not by loci.
