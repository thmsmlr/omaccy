# Worktree CLI Tasks

## Essential Commands

- [x] **`wt list` (or `wt ls`)** - List all worktrees for the current project or all projects. Shows branch names, paths, and current status (active, locked, etc.).

- [x] **`wt delete <branch>` (or `wt rm`)** - Delete a worktree and optionally its associated branch. Handles cleanup of the directory and git worktree references safely.

## Powerful Integration

- [x] **`wt workspace <branch>` (or `wt ws`)** - Use Hammerspoon IPC to create a new named space for that specific worktree, switch to the space, then launch Ghostty in the correct directory, and launch a browser.

