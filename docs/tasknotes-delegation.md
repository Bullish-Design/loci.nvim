# TaskNotes delegation boundary

Loci does not own task lifecycle state. Tasks belong to **TaskNotes** and markdown frontmatter:

- status, priority, due/scheduled dates, timers, completion, recurrence, task views.

The client provides **no** task commands. Manage tasks through TaskNotes directly — in this config under the
`<leader>n` "Notes" group:

```vim
<leader>nt   " browse tasks (TaskNotesBrowse)
<leader>nT   " new task   (TaskNotesNew)
```

## Workspace association is not task ownership

A workspace may associate with a task's markdown note so activation restores the right context. That
association does **not** make loci the owner of task status or metadata — use TaskNotes for any task edit, and
loci only for workspace activation and cross-tool orchestration.
