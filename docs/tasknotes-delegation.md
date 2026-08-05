# TaskNotes delegation boundary

Loci does not own task lifecycle state. Tasks belong to **TaskNotes** and markdown frontmatter:

- status, priority, due/scheduled dates, timers, completion, recurrence, task views.

The client provides **no** task commands. Manage tasks through TaskNotes directly — in this config
under the `<leader>n` "Notes" group:

```vim
<leader>nt   " browse tasks (TaskNotesBrowse)
<leader>nT   " new task   (TaskNotesNew)
```

## Workspace association is not task ownership

A workspace manifest may reference a task's note as a member document (ref + role). That
association does **not** make loci the owner of task status or metadata — use TaskNotes for any
task edit, and loci only for workspace context, adoption, and cross-tool orchestration. The
engine's `status` shared-property writer (`documents/set_status`) is the project/status line in
frontmatter, not task state.
