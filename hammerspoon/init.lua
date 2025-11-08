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


]]
--
-- Enable IPC for external script access
require("hs.ipc")

-- Make WM global so external scripts can access it
WM = require("wm")

WM:init()

hs.window.animationDuration = 0.05

local SCROLL_IGNORE_APPS = { "Cursor", "iTerm2", "Ghostty", "Code" }
local scrollDown = function()
	WM:scroll("down", { ignoreApps = SCROLL_IGNORE_APPS })
end
local scrollUp = function()
	WM:scroll("up", { ignoreApps = SCROLL_IGNORE_APPS })
end

hs.hotkey.bind({ "ctrl" }, "d", scrollDown, nil, scrollDown)
hs.hotkey.bind({ "ctrl" }, "u", scrollUp, nil, scrollUp)

hs.hotkey.bind({ "cmd", "ctrl" }, "o", function()
	WM:navigateStack("out")
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "i", function()
	WM:navigateStack("in")
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "h", function()
	WM:focusDirection("left")
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "l", function()
	WM:focusDirection("right")
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "j", function()
	WM:focusDirection("down")
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "k", function()
	WM:focusDirection("up")
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "h", function()
	WM:moveDirection("left")
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "l", function()
	WM:moveDirection("right")
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "j", function()
	WM:barf()
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "k", function()
	WM:slurp()
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "tab", function()
	WM:nextScreen()
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "tab", function()
	WM:moveWindowToNextScreen()
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "c", function()
	WM:centerWindow()
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "f", function()
	WM:toggleFullscreen()
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "w", function()
	WM:closeFocusedWindow()
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "=", function()
	WM:resizeFocusedWindowHorizontally(WM.resizeStep)
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "-", function()
	WM:resizeFocusedWindowHorizontally(-WM.resizeStep)
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "=", function()
	WM:resizeFocusedWindowVertically(WM.resizeStep)
end)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "-", function()
	WM:resizeFocusedWindowVertically(-WM.resizeStep)
end)

hs.hotkey.bind({ "cmd", "ctrl" }, "1", function()
	WM:switchToSpace(1)
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "2", function()
	WM:switchToSpace(2)
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "3", function()
	WM:switchToSpace(3)
end)
hs.hotkey.bind({ "cmd", "ctrl" }, "4", function()
	WM:switchToSpace(4)
end)

hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "1", function()
	WM:moveFocusedWindowToSpace(1)
end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "2", function()
	WM:moveFocusedWindowToSpace(2)
end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "3", function()
	WM:moveFocusedWindowToSpace(3)
end)
hs.hotkey.bind({ "cmd", "ctrl", "alt" }, "4", function()
	WM:moveFocusedWindowToSpace(4)
end)

-- Command Palette (fuzzy finder for commands and spaces) --
hs.hotkey.bind({ "cmd", "ctrl" }, "`", function()
	if WM.commandPalette and WM.commandPalette:isVisible() and WM.commandPalette.selectedRow then
		-- Cycle to next item
		local current = WM.commandPalette:selectedRow() or 1
		local total = WM.commandPalette:rows()

		if total > 0 then
			local next = (current % total) + 1
			WM.commandPalette:selectedRow(next)

			-- If selection didn't change (hit invalid row), wrap to 1
			if WM.commandPalette:selectedRow() == current then
				WM.commandPalette:selectedRow(1)
			end
		end
	else
		-- Show palette normally
		WM:showCommandPalette()
	end
end)

hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "`", function()
	if WM.commandPalette and WM.commandPalette:isVisible() and WM.commandPalette.selectedRow then
		-- Cycle to previous item
		local current = WM.commandPalette:selectedRow() or 1
		local total = WM.commandPalette:rows()

		if total > 0 then
			local prev = ((current - 2 + total) % total) + 1
			WM.commandPalette:selectedRow(prev)

			-- If selection didn't change (hit invalid row), find last valid row
			if WM.commandPalette:selectedRow() == current then
				for i = total, 1, -1 do
					WM.commandPalette:selectedRow(i)
					if WM.commandPalette:selectedRow() == i then
						break
					end
				end
			end
		end
	else
		-- Show palette normally
		WM:showCommandPalette()
	end
end)

-- App Launcher Shortcuts --

local function applicationHotkey(key, appName, command, opts)
	hs.hotkey.bind({ "cmd", "ctrl" }, key, function()
		local newOpts = {}
		for k, v in pairs(opts) do
			newOpts[k] = v
		end
		newOpts.focusIfExists = true
		WM:launchOrFocusApp(appName, command, newOpts)
	end)
	hs.hotkey.bind({ "cmd", "ctrl", "shift" }, key, function()
		local newOpts = {}
		for k, v in pairs(opts) do
			newOpts[k] = v
		end
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

applicationHotkey("t", "Ghostty", "open -njga '/Applications/Ghostty.app'", { launchViaMenu = true })
applicationHotkey("b", "Google Chrome", "/Users/thomas/.local/bin/chrome", { launchViaMenu = true })
applicationHotkey("e", "Cursor", "open -njga '/Applications/Cursor.app'", { launchViaMenu = true })
applicationHotkey("s", "Slack", "open -a '/Applications/Slack.app'", { singleton = true })
applicationHotkey("n", "Notes", "open -a '/System/Applications/Notes.app'", { singleton = true })
applicationHotkey("x", "X", 'open -na "/Users/thomas/Applications/Chrome Apps.localized/X.app"', { singleton = true })
applicationHotkey(
	"y",
	"YouTube",
	'open -na "/Users/thomas/Applications/Chrome Apps.localized/YouTube.app"',
	{ singleton = true }
)
applicationHotkey(
	"a",
	"ChatGPT",
	"open -gjna '/Applications/Google Chrome.app' --args --app-id='" .. findChromeAppId("ChatGPT") .. "' --new-window",
	{ launchViaMenu = true }
)
applicationHotkey(
	"m",
	"Messages",
	"open -gjna '/Applications/Google Chrome.app' --args --app-id='" .. findChromeAppId("Messages") .. "' --new-window",
	{ launchViaMenu = true, singleton = true }
)

-- Reload --
hs.hotkey.bind({ "cmd", "ctrl" }, "r", function()
	WM:saveState()
	hs.reload()
end)
