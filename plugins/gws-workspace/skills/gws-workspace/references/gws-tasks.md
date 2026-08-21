# tasks (v1)

```bash
gws tasks <resource> <method> [flags]
```

## API Resources

### tasklists

| Method | Description |
| --- | --- |
| `insert` | Creates a new task list (up to 2,000 lists per user) |
| `get` | Returns the specified task list |
| `list` | Returns all task lists for the authenticated user |
| `patch` | Updates task list (patch semantics) |
| `update` | Updates task list (full replace) |
| `delete` | Deletes task list. If it contains assigned tasks, both assigned and original tasks are deleted |

### tasks

| Method | Description |
| --- | --- |
| `insert` | Creates a new task (up to 20,000 non-hidden tasks per list, 100,000 total) |
| `get` | Returns the specified task |
| `list` | Returns all tasks in the specified task list (excludes assigned tasks by default) |
| `patch` | Updates task (patch semantics) |
| `update` | Updates task (full replace) |
| `move` | Moves task to another position, optionally under a new parent (up to 2,000 subtasks per task) |
| `delete` | Deletes the specified task |
| `clear` | Clears all completed tasks from task list (marks them hidden) |

## Limits

| Limit | Value |
| --- | --- |
| Task lists per user | 2,000 |
| Non-hidden tasks per list | 20,000 |
| Total tasks per user | 100,000 |
| Subtasks per task | 2,000 |

## Notes

- Tasks assigned from Docs or Chat Spaces cannot be created via API — only through the assignment surface
- `patch` uses patch semantics (partial update); `update` replaces the entire resource
