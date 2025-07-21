--[[

This is the default configuration for omaccy,

The omaccy window manager is a scrolling tiled window manager.
Windows are organized full height left to right, with a gap between each window.


There are a lot of keyboard shortcuts so let me give you a heuristic for how to remember them:

- CMD+CTRL is the default modifer for all shortcuts that manage focus of windows
- CMD+SHIFT+CTRL is the default modifer for all shortcuts moves or modifies windows

(one exception: CMD+CTRL+ALT is the default modifer for all shortcuts that move windows to a different space since it would otherwise interfere with the default screenshot shortcut)

Movement shortcuts:
- h/l/j/k: move focus left/right/down/up
- shift+h/l/j/k: move window left/right/down/up
- i/o: slurp/barf window
- tab: next screen
- shift+tab: move window to next screen


]] --
local WM = require("wm")

WM:init()

local SCROLL_IGNORE_APPS = { "Cursor", "iTerm2" }
local scrollDown = function() WM:scroll("down", { ignoreApps = SCROLL_IGNORE_APPS }) end
local scrollUp = function() WM:scroll("up", { ignoreApps = SCROLL_IGNORE_APPS }) end

hs.hotkey.bind({ "ctrl" }, "d", scrollDown, nil, scrollDown)
hs.hotkey.bind({ "ctrl" }, "u", scrollUp, nil, scrollUp)

hs.hotkey.bind({ "cmd", "ctrl" }, "o", function() WM:navigateStack("out") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "i", function() WM:navigateStack("in") end)

hs.hotkey.bind({ "cmd", "ctrl" }, "h", function() WM:focusDirection("left") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "l", function() WM:focusDirection("right") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "j", function() WM:focusDirection("down") end)
hs.hotkey.bind({ "cmd", "ctrl" }, "k", function() WM:focusDirection("up") end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "h", function() WM:moveDirection("left") end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "l", function() WM:moveDirection("right") end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "j", function() WM:barf() end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "k", function() WM:slurp() end)

hs.hotkey.bind({ "cmd", "ctrl" }, "tab", function() WM:nextScreen() end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "tab", function() WM:moveWindowToNextScreen() end)

hs.hotkey.bind({ "cmd", "ctrl" }, "c", function() WM:centerWindow() end)
hs.hotkey.bind({ "cmd", "ctrl" }, "f", function() WM:toggleFullscreen() end)
hs.hotkey.bind({ "cmd", "ctrl" }, "w", function() WM:closeFocusedWindow() end)

hs.hotkey.bind({ "cmd", "ctrl" }, "=", function() WM:resizeFocusedWindowHorizontally(WM.resizeStep) end)
hs.hotkey.bind({ "cmd", "ctrl" }, "-", function() WM:resizeFocusedWindowHorizontally(-WM.resizeStep) end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "=", function() WM:resizeFocusedWindowVertically(WM.resizeStep) end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "-", function() WM:resizeFocusedWindowVertically(-WM.resizeStep) end)

hs.hotkey.bind({ "cmd", "ctrl" }, "1", function() WM:switchToSpace(1) end)
hs.hotkey.bind({ "cmd", "ctrl" }, "2", function() WM:switchToSpace(2) end)
hs.hotkey.bind({ "cmd", "ctrl" }, "3", function() WM:switchToSpace(3) end)
hs.hotkey.bind({ "cmd", "ctrl" }, "4", function() WM:switchToSpace(4) end)

hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "1", function() WM:moveFocusedWindowToSpace(1) end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "2", function() WM:moveFocusedWindowToSpace(2) end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "3", function() WM:moveFocusedWindowToSpace(3) end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "4", function() WM:moveFocusedWindowToSpace(4) end)

-- App Launcher Shortcuts --

local function applicationHotkey(key, appName, command, opts)
    hs.hotkey.bind({ "cmd", "ctrl" }, key, function()
        local newOpts = {}
        for k, v in pairs(opts) do newOpts[k] = v end
        newOpts.focusIfExists = true
        WM:launchOrFocusApp(appName, command, newOpts)
    end)
    hs.hotkey.bind({ "cmd", "ctrl", "shift" }, key, function()
        local newOpts = {}
        for k, v in pairs(opts) do newOpts[k] = v end
        newOpts.focusIfExists = false
        WM:launchOrFocusApp(appName, command, newOpts)
    end)
end

local function findChromeAppId(appName)
    -- Build the path to the app's Info.plist
    local home = os.getenv("HOME")
    local appPath = string.format("%s/Applications/Chrome Apps.localized/%s.app/Contents/Info.plist", home, appName)
    local plistBuddy = "/usr/libexec/PlistBuddy"
    local cmd = string.format("'%s' -c 'Print :CrAppModeShortcutID' '%s' 2>/dev/null", plistBuddy, appPath)
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end
    local result = handle:read("*a")
    handle:close()
    result = result and result:gsub("%s+$", "") -- trim trailing whitespace
    if result == "" then
        return nil
    end
    return result
end

applicationHotkey("b", "Google Chrome", "open -njga '/Applications/Google Chrome.app'", { launchViaMenu = true })
applicationHotkey("e", "Cursor", "open -njga '/Applications/Cursor.app'", { launchViaMenu = true })
applicationHotkey("s", "Spotify", "open -a '/Applications/Spotify.app'", { singleton = true })
applicationHotkey("m", "Messages", "open -a '/System/Applications/Messages.app'", { singleton = true })
applicationHotkey("x", "X", 'open -na "/Users/thomas/Applications/Chrome Apps.localized/X.app"', { singleton = true })
applicationHotkey("y", "YouTube", 'open -na "/Users/thomas/Applications/Chrome Apps.localized/YouTube.app"',
{ singleton = true })
applicationHotkey("a", "ChatGPT",
    "open -gjna '/Applications/Google Chrome.app' --args --app-id='" .. findChromeAppId("ChatGPT") .. "' --new-window",
    { launchViaMenu = true })

-- Reload --
hs.hotkey.bind({ "cmd", "ctrl" }, "r", function()
    WM:saveState()
    hs.reload()
end)
