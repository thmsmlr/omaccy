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
local watcherReenableAfter = 0  -- timestamp after which watcher should be re-enabled
local watcherMonitorTimer = nil -- perpetual timer to check if watcher should be re-enabled

------------------------------------------
-- Helper functions
------------------------------------------

-- Insert a window into state at a specific position, creating the column if needed
local function insertWindowAtPosition(winId, screenId, spaceId, colIdx, rowIdx)
	-- Ensure screen/space structure exists
	if not state.screens[screenId] then
		state.screens[screenId] = {}
	end
	if not state.screens[screenId][spaceId] then
		state.screens[screenId][spaceId] = { cols = {}, floating = {} }
	end
	if not state.startXForScreenAndSpace[screenId] then
		state.startXForScreenAndSpace[screenId] = {}
	end
	if not state.startXForScreenAndSpace[screenId][spaceId] then
		state.startXForScreenAndSpace[screenId][spaceId] = 0
	end

	local cols = state.screens[screenId][spaceId].cols

	-- If colIdx is beyond current columns, create new column at the end
	if colIdx > #cols then
		colIdx = #cols + 1
		cols[colIdx] = {}
	end

	-- If rowIdx is specified and valid, insert at that position
	if rowIdx and rowIdx <= #cols[colIdx] + 1 then
		table.insert(cols[colIdx], rowIdx, winId)
	else
		table.insert(cols[colIdx], winId)
	end

	return screenId, spaceId, colIdx, rowIdx or #cols[colIdx]
end

------------------------------------------
-- Window event handlers
------------------------------------------

-- Disable watcher for a specified duration (in seconds)
-- Multiple calls extend the disable period to the latest end time (debouncing)
function Events.disableWatcherFor(duration)
	duration = duration or 0.1
	local newReenableTime = hs.timer.secondsSinceEpoch() + duration

	-- Extend the disable period if this would end later
	if newReenableTime > watcherReenableAfter then
		watcherReenableAfter = newReenableTime
	end

	windowWatcherPaused = true
end

-- Legacy function for backward compatibility
function Events.pauseWatcher()
	Events.disableWatcherFor(0.1)
end

-- Legacy function for backward compatibility
-- Sets the re-enable timestamp to now + delay (debounced with any existing disable)
function Events.resumeWatcher(delay)
	delay = delay or 0.1
	local newReenableTime = hs.timer.secondsSinceEpoch() + delay

	-- Extend the disable period if this would end later
	if newReenableTime > watcherReenableAfter then
		watcherReenableAfter = newReenableTime
	end
end

function Events.isPaused()
	return windowWatcherPaused
end

-- Start the perpetual timer that monitors and re-enables the watcher
local function startWatcherMonitor()
	if watcherMonitorTimer then return end

	watcherMonitorTimer = hs.timer.doEvery(0.05, function()
		if windowWatcherPaused and hs.timer.secondsSinceEpoch() >= watcherReenableAfter then
			windowWatcherPaused = false
		end
	end)
end

-- Stop the monitor timer
local function stopWatcherMonitor()
	if watcherMonitorTimer then
		watcherMonitorTimer:stop()
		watcherMonitorTimer = nil
	end
end

function Events.stop()
	stopWatcherMonitor()
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

		-- If window not in state, check if it should replace a missing tabbed window
		if not screenId or not spaceId or not colIdx or not rowIdx then
			-- Find a missing window and replace it
			local replaced = false

			for sid, spaces in pairs(state.screens) do
				for spid, space in pairs(spaces) do
					if state.activeSpaceForScreen[sid] == spid then
						for ci, col in ipairs(space.cols) do
							for ri, otherWinId in ipairs(col) do
								local otherWin = hs.window(otherWinId)
								if not otherWin then
									print("[windowFocused] Replacing missing window " .. otherWinId .. " with " .. winId .. " in col " .. ci)
									col[ri] = winId
									screenId, spaceId, colIdx, rowIdx = sid, spid, ci, ri
									replaced = true
									break
								end
							end
							if replaced then break end
						end
					end
					if replaced then break end
				end
				if replaced then break end
			end

			if not replaced then
				-- No missing window to replace - add as new column
				local screen = win:screen()
				local sid = screen and screen:id() or hs.screen.mainScreen():id()
				local spid = state.activeSpaceForScreen[sid] or 1

				screenId, spaceId, colIdx, rowIdx = insertWindowAtPosition(winId, sid, spid, 9999, 1)
				print("[windowFocused] Added new window " .. winId .. " to col " .. colIdx)

				-- Retile to position the new window
				retileAll()
				return
			end
		end

		-- Clean up missing windows from this screen/space (handles tabbed windows where one tab "disappears")
		local cols = state.screens[screenId][spaceId].cols
		local cleanedUp = false
		for ci = #cols, 1, -1 do
			local col = cols[ci]
			for ri = #col, 1, -1 do
				local otherWinId = col[ri]
				if otherWinId ~= winId then
					local otherWin = hs.window(otherWinId)
					if not otherWin then
						print("[windowFocused] Cleaning up missing window " .. otherWinId .. " from col " .. ci)
						table.remove(col, ri)
						cleanedUp = true
					end
				end
			end
			-- Remove empty columns
			if #col == 0 then
				table.remove(cols, ci)
			end
		end

		-- If we cleaned up windows, re-locate the focused window (column indices may have changed)
		if cleanedUp then
			screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
			if not screenId or not spaceId or not colIdx or not rowIdx then
				return
			end
		end

		-- Check for tabbed windows: if this window's frame matches another window in a different column,
		-- they are likely tabs sharing the same physical window. Consolidate them.
		local winFrame = win:frame()
		local consolidatedWithCol = nil

		for otherColIdx, col in ipairs(cols) do
			if otherColIdx ~= colIdx then
				for _, otherWinId in ipairs(col) do
					local otherWin = Windows.getWindow(otherWinId)
					if otherWin then
						local otherFrame = otherWin:frame()
						-- Check if frames match (within tolerance) - indicates tabbed windows
						local frameTolerance = 5
						if math.abs(winFrame.x - otherFrame.x) <= frameTolerance
							and math.abs(winFrame.y - otherFrame.y) <= frameTolerance
							and math.abs(winFrame.w - otherFrame.w) <= frameTolerance
							and math.abs(winFrame.h - otherFrame.h) <= frameTolerance then
							consolidatedWithCol = otherColIdx
							break
						end
					end
				end
			end
			if consolidatedWithCol then break end
		end

		if consolidatedWithCol then
			-- Consolidate: move focused window to the other column, remove old entry
			print("[windowFocused] Consolidating tabbed window " .. winId .. " from col " .. colIdx .. " to col " .. consolidatedWithCol)

			-- Remove from old column
			local oldCol = cols[colIdx]
			for i = #oldCol, 1, -1 do
				if oldCol[i] == winId then
					table.remove(oldCol, i)
					break
				end
			end

			-- If old column is now empty, remove it
			if #oldCol == 0 then
				table.remove(cols, colIdx)
			end

			-- Add to the consolidated column (at the end, as a row)
			local targetCol = cols[consolidatedWithCol > colIdx and consolidatedWithCol - 1 or consolidatedWithCol]
			table.insert(targetCol, winId)

			-- Retile to fix positions, but don't call bringIntoView since we're already in the right spot
			retile(screenId, spaceId)
			return
		end

		-- If we cleaned up windows, retile to fix positions and skip bringIntoView
		-- since the window is likely already in the correct position
		if cleanedUp then
			retile(screenId, spaceId)
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
		local destroyedAppName = appName

		-- Clean up urgentWindows unconditionally (before early return)
		if state.urgentWindows[winId] then
			state.urgentWindows[winId] = nil
			updateMenubar()
		end

		-- Clean up fullscreenOriginalWidth unconditionally (before early return)
		state.fullscreenOriginalWidth[winId] = nil

		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if not screenId or not spaceId or not colIdx or not rowIdx then
			return
		end

		-- Save position info before removal for tabbed window handling
		local savedScreenId, savedSpaceId, savedColIdx, savedRowIdx = screenId, spaceId, colIdx, rowIdx

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
		local columnWasRemoved = false
		if #col == 0 then
			table.remove(state.screens[screenId][spaceId].cols, colIdx)
			columnWasRemoved = true
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

		-- Retile all screens/spaces (could optimize to just affected ones)
		retileAll()

		-- Handle tabbed windows: check if macOS focused a sibling tab
		hs.timer.doAfter(0.05, function()
			local newFocused = hs.window.focusedWindow()
			if not newFocused then
				return
			end

			local newWinId = newFocused:id()
			local newAppName = newFocused:application():name()

			-- Check if new focused window is from the same app and not in state
			if newAppName == destroyedAppName then
				local existingScreenId = locateWindow(newWinId)
				if not existingScreenId then
					-- This is likely a sibling tab - insert it at the saved position
					print(string.format("[windowDestroyed] Inserting sibling tab %d at col %d", newWinId, savedColIdx))

					-- If the column was removed, we need to create it again
					local targetColIdx = columnWasRemoved and savedColIdx or savedColIdx
					local targetRowIdx = columnWasRemoved and 1 or savedRowIdx

					insertWindowAtPosition(newWinId, savedScreenId, savedSpaceId, targetColIdx, targetRowIdx)
					addToWindowStack(newFocused)
					retile(savedScreenId, savedSpaceId)
				end
			end
		end)
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

	-- Start the monitor timer that re-enables the watcher after disable periods
	startWatcherMonitor()
	profile("start watcher monitor")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[Events] Module initialized - TOTAL: %.2fms", totalTime))
end

return Events
