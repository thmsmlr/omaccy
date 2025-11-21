# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omaccy is a scrolling tiled window manager for macOS built on Hammerspoon. Windows are organized full-height left-to-right with gaps. The main code lives in `hammerspoon/` which symlinks to `~/.hammerspoon`.

## Key Commands

- **Reload config**: `hs -c 'WM:saveState(); hs.reload()'` (save state first, wait 2s for reload)
- **Test functionality**: `hs -c 'WM:init()'`
- **Inspect state**: `hs -c 'return hs.inspect(WM.State.get().urgentWindows)'`
- **Check logs**: `hs -c 'return hs.console.getConsole()'`
- **Locate windows**: `hs -c 'return WM.Windows.locateWindow(12345)'`
- **Validate windows**: `hs -c 'local win = hs.window(12345); return win and win:title() or "not found"'`

## Architecture

```
hammerspoon/
├── init.lua          # Entry point, hotkey bindings, WM initialization
├── wm.lua            # Main WM module orchestration
└── wm/
    ├── actions.lua   # User-facing actions (focus, move, resize, etc.)
    ├── events.lua    # Window/application event handlers
    ├── spaces.lua    # macOS Spaces integration
    ├── state.lua     # State management and persistence
    ├── tiling.lua    # Window tiling/layout algorithms
    ├── ui.lua        # Visual indicators and overlays
    ├── urgency.lua   # Window urgency handling
    └── windows.lua   # Window utilities and helpers
```

## Development Workflow

1. Edit Lua files in `hammerspoon/`
2. Reload with `hs -c 'WM:saveState(); hs.reload()'`
3. Wait ~2s for reload to complete
4. Test changes

## Profiling

```lua
local start = hs.timer.secondsSinceEpoch()
-- code to profile
print(string.format("%.2fms", (hs.timer.secondsSinceEpoch() - start) * 1000))
```

## Important Notes

- Never commit changes before the user has personally verified them unless otherwise instructed
- The `WM` global is exposed for external script access via `hs.ipc`
- Hotkey conventions: `CMD+CTRL` for focus, `CMD+SHIFT+CTRL` for moving/modifying windows
