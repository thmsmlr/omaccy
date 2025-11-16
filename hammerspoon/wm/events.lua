--[[
Events Module

Handles all window event watching and handlers for the window manager.
Manages focus tracking, window creation/destruction, and watcher pause/resume logic.

Dependencies: state, windows, tiling, spaces, urgency
]]
--

local Events = {}

-- Forward declarations for dependencies (set during init)
local WM
local state
local Windows
local Tiling
local Spaces
local Urgency
local UI

-- Local references to functions (set during init)
local addToWindowStack
local cleanWindowStack
local locateWindow
local retile
local retileAll
local moveSpaceWindowsOffscreen
local bringIntoView
local clearWindowUrgent
local updateMenubar

-- Module state
local windowWatcherPaused = false
local windowWatcher = nil

------------------------------------------
-- Window event handlers
------------------------------------------

function Events.pauseWatcher()
	windowWatcherPaused = true
end

function Events.resumeWatcher(delay)
	delay = delay or 0.1
	hs.timer.doAfter(delay, function()
		windowWatcherPaused = false
	end)
end

function Events.isPaused()
	return windowWatcherPaused
end

function Events.stop()
	if windowWatcher then
		print("[Events] Stopping window watcher")
		windowWatcher:unsubscribeAll()
		windowWatcher = nil
	end
end

function Events.init(wm)
	local initStart = hs.timer.secondsSinceEpoch()
	local stepStart = initStart
	local function profile(label)
		local now = hs.timer.secondsSinceEpoch()
		local elapsed = (now - stepStart) * 1000
		print(string.format("[Events profile] %s: %.2fms", label, elapsed))
		stepStart = now
	end

	WM = wm
	state = WM.State.get()
	Windows = WM.Windows
	Tiling = WM.Tiling
	Spaces = WM.Spaces
	Urgency = WM.Urgency
	UI = WM.UI

	-- Cache function references
	addToWindowStack = Windows.addToWindowStack
	cleanWindowStack = Windows.cleanWindowStack
	locateWindow = Windows.locateWindow
	retile = Tiling.retile
	retileAll = Tiling.retileAll
	moveSpaceWindowsOffscreen = Tiling.moveSpaceWindowsOffscreen
	bringIntoView = Tiling.bringIntoView
	clearWindowUrgent = Urgency.clearWindowUrgent
	updateMenubar = UI.updateMenubar
	profile("setup references")

	-- Create window watcher
	windowWatcher = hs.window.filter.new()
	profile("window.filter.new()")

	-- Window focused handler
	windowWatcher:subscribe(hs.window.filter.windowFocused, function(win, appName, event)
		if windowWatcherPaused then
			return
		end
		print("[windowFocused]", win:title(), win:id(), windowWatcherPaused)
		addToWindowStack(win)

		-- Clear urgency for focused window
		local winId = win:id()
		if state.urgentWindows[winId] then
			clearWindowUrgent(winId)
		end

		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if not screenId or not spaceId or not colIdx or not rowIdx then
			return
		end
		if state.activeSpaceForScreen[screenId] ~= spaceId then
			local oldSpaceId = state.activeSpaceForScreen[screenId]
			state.activeSpaceForScreen[screenId] = spaceId
			-- Only retile the affected screen's spaces
			moveSpaceWindowsOffscreen(screenId, oldSpaceId)
			retile(screenId, spaceId)

			-- Update menubar to reflect space change
			updateMenubar()
		end
		bringIntoView(win)
	end)
	profile("subscribe windowFocused")

	-- Window created handler
	windowWatcher:subscribe(hs.window.filter.windowCreated, function(win, appName, event)
		if windowWatcherPaused then
			return
		end
		if not win:isStandard() or not win:isVisible() or win:isFullScreen() then
			return
		end
		print("[windowCreated]", win:title(), win:id())

		-- If the window is already on a screen, don't do anything
		local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
		if screenId ~= nil then
			return
		end

		-- Place new window in the current space/column
		local screen = win:screen()
		local screenId = screen and screen:id() or hs.screen.mainScreen():id()
		local spaceId = state.activeSpaceForScreen[screenId] or 1

		-- Place in a new column at the end
		local cols = state.screens[screenId][spaceId].cols
		local colIdx = #cols + 1
		cols[colIdx] = cols[colIdx] or {}
		table.insert(cols[colIdx], win:id())

		addToWindowStack(win)
		cleanWindowStack()
		retileAll()
	end)
	profile("subscribe windowCreated")

	-- Window destroyed handler
	windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(win, appName, event)
		if windowWatcherPaused then
			return
		end
		print("[windowDestroyed]", win:title(), win:id())

		local winId = win:id()
		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if not screenId or not spaceId or not colIdx or not rowIdx then
			return
		end
		local col = state.screens[screenId][spaceId].cols[colIdx]
		if not col then
			return
		end
		for i = #col, 1, -1 do
			if col[i] == winId then
				table.remove(col, i)
				break
			end
		end
		if #col == 0 then
			table.remove(state.screens[screenId][spaceId].cols, colIdx)
		end

		-- Auto-cleanup empty named spaces (but preserve numbered spaces 1-4)
		local space = state.screens[screenId][spaceId]
		local isEmptySpace = space and #space.cols == 0 and (not space.floating or #space.floating == 0)
		local isNamedSpace = type(spaceId) == "string"

		if isEmptySpace and isNamedSpace then
			print("[windowDestroyed]", "Cleaning up empty named space:", spaceId)
			state.screens[screenId][spaceId] = nil
			state.startXForScreenAndSpace[screenId][spaceId] = nil

			-- If this was the active space, switch to space 1
			if state.activeSpaceForScreen[screenId] == spaceId then
				state.activeSpaceForScreen[screenId] = 1
				updateMenubar()
			end
		end

		-- Clean up the window stack to remove any now-invalid windows
		cleanWindowStack()

		-- Remove from fullscreenOriginalWidth
		state.fullscreenOriginalWidth[winId] = nil

		-- Retile all screens/spaces (could optimize to just affected ones)
		retileAll()
	end)
	profile("subscribe windowDestroyed")

	-- Fullscreen/unfullscreen handler
	windowWatcher:subscribe(
		{ hs.window.filter.windowFullscreened, hs.window.filter.windowUnfullscreened },
		function(win, appName, event)
			if windowWatcherPaused then
				return
			end
			retileAll()
		end
	)
	profile("subscribe fullscreen")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[Events] Module initialized - TOTAL: %.2fms", totalTime))
end

return Events
