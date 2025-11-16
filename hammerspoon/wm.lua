local WM = {}
WM.__index = WM

local serpent = dofile(hs.configdir .. "/serpent.lua")

-- Metadata
WM.name = "WM"
WM.version = "0.1"
WM.author = "Thomas Millar"
WM.homepage = "https://github.com/thmslmr/omaccy"
WM.license = "MIT - https://opensource.org/licenses/MIT"

WM.log = hs.logger.new(WM.name)
WM.log.setLogLevel("debug")

WM.tileGap = 10
WM.resizeStep = 200
WM.scrollSpeed = 400

local Application <const> = hs.application
local Axuielement <const> = hs.axuielement
local Event <const> = hs.eventtap.event
local EventTypes <const> = hs.eventtap.event.types
local Geometry <const> = hs.geometry
local Mouse <const> = hs.mouse
local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Window <const> = hs.window
local Settings <const> = hs.settings
local FnUtils <const> = hs.fnutils
local json <const> = hs.json

-- Load submodules
WM.State = dofile(hs.configdir .. "/wm/state.lua")
WM.Windows = dofile(hs.configdir .. "/wm/windows.lua")
WM.Tiling = dofile(hs.configdir .. "/wm/tiling.lua")
WM.Spaces = dofile(hs.configdir .. "/wm/spaces.lua")
WM.Urgency = dofile(hs.configdir .. "/wm/urgency.lua")
WM.UI = dofile(hs.configdir .. "/wm/ui.lua")
WM.Events = dofile(hs.configdir .. "/wm/events.lua")
WM.Actions = dofile(hs.configdir .. "/wm/actions.lua")

-- Get state reference from State module
local state = WM.State.get()

--[[

This is a PaperWM style scrolling window manager.
This implementation has some key differences that improve the experience:

- We do not rely on the events fired by MacOS, specifically Chrome will do a bunch of weird non-standard things firing tons of events that can wreck the state of the window manager.
- The state is stored in hs.settings so that it is preserved across reloads.
- We do not rely on the spaces API, because then we have to fight with focus management for Chrome -- a notoriously unreliable offender of the MacOS focus system.
  Instead, windows that in a non-focused space are put on the rightmost edge of the rightmost screen. Visually they are gone, but we are only using a single MacOS Space.
- To support multiple monitors, we can't position windows fully offscreen because MacOS will move them to the screen the majority of their pixels are on,
  Therefore, for the current space, windows can only ever be max 50% - 1px offscreen this makes the window manager look more like the old coverflow from the iPod than proper PaperWM.
  In practice it works and doesn't meaningfully affect the experience.

Underhood the main functions are:

- retile(screenId, spaceId, opts) -> tiles the windows on the given screen and space

The state looks like this:

{
    -- What windows are on each screen in each space in each column/row
    screens -> {
        screenId -> {
            spaceId -> {
                cols -> {
                    { window:id(), ... },
                    { window:id(), ... },
                    ...
                }
                floating -> {
                    window:id(),
                    ...
                }
            }
        }
    },
    -- What space is currently active on each screen
    activeSpaceForScreen -> {
        screenId -> spaceId,
        ...
    },
    -- The x position of the first window on each screen in each space
    startXForScreenAndSpace -> {
        screenId -> {
            spaceId -> x,
            ...
        },
        ...
    },
    -- The original width of the focused window when it was last fullscreened
    fullscreenOriginalWidth -> {
        window:id() -> width,
        ...
    },
    -- a LRU cache of the most recently focused windows
    windowStack -> {
        window:id(),
        ...
    }
}


The main actions one can take are:

- [x] switchToSpace(spaceId) -> focus the given space
- [x] focusDirection("left" | "right" | "up" | "down") -> focus the window in the given direction
- [x] moveDirection("left" | "right") -> move the focused window in the given direction in the tile order
- [x] slurp() -> move the focused window into the same column as the window to it's left
- [x] barf() -> move the focused window out of it's current column into it's own column to the right
- [x] toggleFullscreen() -> toggle the fullscreen state of the focused window
- [x] switchToNextScreen() -> switch to the next screen
- [x] moveToNextScreen() -> move the focused window to the next screen
- [x] nextScreen() -> switch to the next screen
- [ ] toggleFloating() -> toggle the floating state of the focused window

Other TODOs:

- [x] reload should saveState()
- [x] saveState / init should preserve the windowStack, activeSpaceForScreen, startXForScreenAndSpace, fullscreenOriginalWidth
- [x] retile should handle rows
- [x] focusDirection should handle rows, cmd+ctrl+{j,k}
- [x] slurp/barf cmd+ctrl+shift+{j,k}
- [x] resizeFocusedWindow should handle rows
- [x] resizeFocusedWindow should expand when on right edge of screen
- [x] retile should raise windows in a way that handles rows
- [x] Window focus handler to update the windowStack
- [x] If a window is click focused (or alt-tabbed) we should switch it it's space and bringIntoView
- [x] into/outof windowStack cmd+ctrl+{i,o}
- [x] Window created/destroyed should retile and filter from windowStack
- [x] cmd+ctrl+w should close the focused window and shift focus to the last window in the stack
- [x] navigateStack should switch spaces if needed
- [x] switchToSpace should use earliestIndexInList to find the last window on that space focused instead of first.
- [x] Launch application shortcuts
    - [x] pause watcher, wait for new window, add to state, retile, start watcher
    - [x] launchViaMenu
    - [x] focusIfExists
    - [x] singleton
- [ ] switchToSpace should appropriately handle floating windows.
- [x] Retile should manage z-index of windows across columns and rows using getOrderedWindows()
- [ ] When a screen is removed, all spaces on that screen should be moved to the rightmost screen


]]
--

------------------------------------------
-- Helpers
------------------------------------------

-- Convenience aliases for Windows module functions
local getWindow = function(...) return WM.Windows.getWindow(...) end
local cleanWindowStack = function(...) return WM.Windows.cleanWindowStack(...) end
local focusWindow = function(...) return WM.Windows.focusWindow(...) end
local locateWindow = function(...) return WM.Windows.locateWindow(...) end
local updateZOrder = function(...) return WM.Windows.updateZOrder(...) end
local framesDiffer = function(...) return WM.Windows.framesDiffer(...) end
local centerMouseInWindow = function(...) return WM.Windows.centerMouseInWindow(...) end
local addToWindowStack = function(...) return WM.Windows.addToWindowStack(...) end
local flatten = function(...) return WM.Windows.flatten(...) end
local earliestIndexInList = function(...) return WM.Windows.earliestIndexInList(...) end

-- Convenience aliases for Tiling module functions
local retile = function(...) return WM.Tiling.retile(...) end
local retileAll = function(...) return WM.Tiling.retileAll(...) end
local bringIntoView = function(...) return WM.Tiling.bringIntoView(...) end
local moveSpaceWindowsOffscreen = function(...) return WM.Tiling.moveSpaceWindowsOffscreen(...) end
local getRightmostScreen = function(...) return WM.Tiling.getRightmostScreen(...) end

-- Convenience aliases for Spaces module functions
local getSpaceForWindow = function(...) return WM.Spaces.getSpaceForWindow(...) end
local getSpaceMRUOrder = function(...) return WM.Spaces.getSpaceMRUOrder(...) end
local getUrgentWindowsInSpace = function(...) return WM.Spaces.getUrgentWindowsInSpace(...) end
local isSpaceUrgent = function(...) return WM.Spaces.isSpaceUrgent(...) end
local buildSpaceList = function(...) return WM.Spaces.buildSpaceList(...) end

-- Convenience aliases for Urgency module functions
local setWindowUrgent = function(...) return WM.Urgency.setWindowUrgent(...) end
local clearWindowUrgent = function(...) return WM.Urgency.clearWindowUrgent(...) end
local hasUrgentWindows = function(...) return WM.Urgency.hasUrgentWindows(...) end

-- Convenience aliases for UI module functions
local updateMenubar = function(...) return WM.UI.updateMenubar(...) end
local updateCommandPalette = function(...) return WM.UI.getUpdateCommandPalette()(...) end


------------------------------------------
-- Action method delegation to Actions module
------------------------------------------

function WM:navigateStack(direction)
	return WM.Actions.navigateStack(direction)
end

function WM:focusDirection(direction)
	return WM.Actions.focusDirection(direction)
end

function WM:moveDirection(direction)
	return WM.Actions.moveDirection(direction)
end

function WM:nextScreen()
	return WM.Actions.nextScreen()
end

function WM:moveWindowToNextScreen()
	return WM.Actions.moveWindowToNextScreen()
end

function WM:toggleFullscreen()
	return WM.Actions.toggleFullscreen()
end

function WM:centerWindow()
	return WM.Actions.centerWindow()
end

function WM:resizeFocusedWindowHorizontally(delta)
	return WM.Actions.resizeFocusedWindowHorizontally(delta)
end

function WM:resizeFocusedWindowVertically(delta)
	return WM.Actions.resizeFocusedWindowVertically(delta)
end

function WM:switchToSpace(spaceId)
	return WM.Actions.switchToSpace(spaceId)
end

function WM:slurp()
	return WM.Actions.slurp()
end

function WM:barf()
	return WM.Actions.barf()
end

function WM:moveFocusedWindowToSpace(spaceId)
	return WM.Actions.moveFocusedWindowToSpace(spaceId)
end

function WM:closeFocusedWindow()
	return WM.Actions.closeFocusedWindow()
end

function WM:createSpace(spaceId, screenId)
	return WM.Actions.createSpace(spaceId, screenId)
end

function WM:renameSpace(screenId, oldSpaceId, newSpaceId)
	return WM.Actions.renameSpace(screenId, oldSpaceId, newSpaceId)
end

------------------------------------------
-- Urgency methods
------------------------------------------

-- Delegate urgency methods to Urgency module
function WM:setWindowUrgent(winId, urgent)
	return WM.Urgency.setWindowUrgent(winId, urgent)
end

function WM:clearWindowUrgent(winId)
	return WM.Urgency.clearWindowUrgent(winId)
end

function WM:debugUrgentWindows()
	return WM.Urgency.debugUrgentWindows()
end

function WM:setCurrentWindowUrgent()
	return WM.Urgency.setCurrentWindowUrgent()
end

function WM:setUrgentByApp(appName)
	return WM.Urgency.setUrgentByApp(appName)
end

function WM:clearAllUrgent()
	return WM.Urgency.clearAllUrgent()
end

function WM:scroll(direction, opts)
	return WM.Actions.scroll(direction, opts)
end

function WM:launchOrFocusApp(appName, launchCommand, opts)
	return WM.Actions.launchOrFocusApp(appName, launchCommand, opts)
end

function WM:saveState()
	WM.State.save()
end

-- Setup UI components (menubar and command palette)
-- Delegate showCommandPalette to UI module
function WM:showCommandPalette()
	return WM.UI.showCommandPalette()
end

function WM:init()
	local initStart = hs.timer.secondsSinceEpoch()
	local stepStart = initStart
	local function profile(label)
		local now = hs.timer.secondsSinceEpoch()
		local elapsed = (now - stepStart) * 1000
		print(string.format("[profile] %s: %.2fms", label, elapsed))
		stepStart = now
	end

	print("[init] Starting window manager initialization")

	-- 0. Stop existing resources if reinitializing
	if WM.Events and WM.Events.stop then
		WM.Events.stop()
	end
	if WM.UI and WM.UI.stop then
		WM.UI.stop()
	end
	profile("Stop existing resources")

	-- 1. Initialize State module (handles loading, cleaning, migration, reconciliation)
	WM.State.init(WM)
	profile("State.init")

	-- 2. Initialize Windows module
	WM.Windows.init(WM)
	profile("Windows.init")

	-- 3. Initialize Tiling module
	WM.Tiling.init(WM)
	profile("Tiling.init")

	-- 4. Initialize Spaces module
	WM.Spaces.init(WM)
	profile("Spaces.init")

	-- 5. Initialize UI module (must come before Urgency since Urgency needs updateMenubar)
	WM.UI.init(WM, state, WM.Spaces, WM.Urgency, WM.Windows)
	profile("UI.init")

	-- 6. Initialize Urgency module
	WM.Urgency.init(WM, state, WM.Windows, updateMenubar, updateCommandPalette)
	profile("Urgency.init")

	-- 6a. Now that Urgency is initialized, update menubar for the first time
	updateMenubar()
	profile("updateMenubar")

	-- 7. Initialize Events module
	WM.Events.init(WM)
	profile("Events.init")

	-- 8. Initialize Actions module
	WM.Actions.init(WM)
	profile("Actions.init")

	-- 9. Clean window stack
	cleanWindowStack()
	profile("cleanWindowStack")

	-- 10. Retile all spaces
	local retileStart = hs.timer.secondsSinceEpoch()
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if state.activeSpaceForScreen[screenId] == spaceId then
				retile(screenId, spaceId)
			else
				moveSpaceWindowsOffscreen(screenId, spaceId)
			end
		end
	end
	profile("Retile all spaces")

	-- 11. Set UI callbacks for Windows module
	WM.Windows.setUICallbacks(updateMenubar, updateCommandPalette)
	profile("setUICallbacks")

	-- 12. Add focused window to stack
	addToWindowStack(Window.focusedWindow())
	profile("addToWindowStack")

	-- 13. Expose command palette for hotkey access
	WM.commandPalette = WM.UI.commandPalette

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[init] Initialization complete - TOTAL: %.2fms", totalTime))
end

hs.hotkey.bind({ "cmd", "ctrl" }, "t", function()
	print(hs.inspect(state.screens))
end)

return WM
