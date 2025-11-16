- Never commit changes before the human has been able to personally verify your changes unless otherwise instructed.

## Debugging Workflow

Use the `hs` command line tool to verify changes:

1. **Reload config**: `hs -c 'WM:saveState(); hs.reload()'` (save state first, wait 2s for reload)
2. **Test functionality**: `hs -c 'WM:init()'` or call specific functions
3. **Inspect state**: `hs -c 'return hs.inspect(WM.State.get().urgentWindows)'`
4. **Check logs**: `hs -c 'return hs.console.getConsole()'`
5. **Locate windows**: `hs -c 'return WM.Windows.locateWindow(12345)'`
6. **Validate windows**: `hs -c 'local win = hs.window(12345); return win and win:title() or "not found"'`

For profiling, add timing with `hs.timer.secondsSinceEpoch()` and print results:
```lua
local start = hs.timer.secondsSinceEpoch()
-- code to profile
print(string.format("%.2fms", (hs.timer.secondsSinceEpoch() - start) * 1000))
```