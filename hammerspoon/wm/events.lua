--[[
Events Module

Handles all window event watching and handlers for the window manager.
Uses a reconciliation-based approach: events trigger a diff of actual vs tracked
window state, making the system resilient to unreliable macOS window events.

Focus tracking uses debouncing to filter out spurious focus events during
rapid window create/destroy cycles.

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
local windowWatcher = nil
local reconcileTimer = nil      -- debounce timer for reconciliation
local focusCommitTimer = nil    -- debounce timer for focus tracking
local pendingFocusWinId = nil   -- pending focus to commit after settling
local suppressFocusCommit = false -- flag to suppress focus commits during WM operations

------------------------------------------
-- Helper functions
------------------------------------------

-- Remove a window from state given its position
local function removeWindowFromState(winId, pos)
	local space = state.screens[pos.screenId] and state.screens[pos.screenId][pos.spaceId]
	if not space then return false end

	local col = space.cols[pos.colIdx]
	if not col then return false end

	-- Remove window from column
	for i = #col, 1, -1 do
		if col[i] == winId then
			table.remove(col, i)
			break
		end
	end

	-- Track if column was removed for ratio shifting
	local columnWasRemoved = false
	if #col == 0 then
		table.remove(space.cols, pos.colIdx)
		columnWasRemoved = true
	end

	-- Clear/shift height ratios
	if state.columnHeightRatios[pos.screenId] and state.columnHeightRatios[pos.screenId][pos.spaceId] then
		local spaceRatios = state.columnHeightRatios[pos.screenId][pos.spaceId]
		if columnWasRemoved then
			local maxIdx = 0
			for k in pairs(spaceRatios) do
				if k > maxIdx then maxIdx = k end
			end
			for i = pos.colIdx, maxIdx do
				spaceRatios[i] = spaceRatios[i + 1]
			end
		else
			spaceRatios[pos.colIdx] = nil
		end
	end

	-- Clean up urgentWindows
	if state.urgentWindows[winId] then
		state.urgentWindows[winId] = nil
		updateMenubar()
	end

	-- Clean up fullscreenOriginalWidth
	state.fullscreenOriginalWidth[winId] = nil

	-- Auto-cleanup empty named spaces (preserve numbered spaces 1-4)
	local isEmptySpace = #space.cols == 0 and (not space.floating or #space.floating == 0)
	local isNamedSpace = type(pos.spaceId) == "string"

	if isEmptySpace and isNamedSpace then
		print("[reconcile] Cleaning up empty named space:", pos.spaceId)
		state.screens[pos.screenId][pos.spaceId] = nil
		if state.startXForScreenAndSpace[pos.screenId] then
			state.startXForScreenAndSpace[pos.screenId][pos.spaceId] = nil
		end

		if state.activeSpaceForScreen[pos.screenId] == pos.spaceId then
			state.activeSpaceForScreen[pos.screenId] = 1
			updateMenubar()
		end
	end

	return true
end

-- Add a window to a new column in the given screen/space
local function addWindowToNewColumn(winId, screenId)
	local spaceId = state.activeSpaceForScreen[screenId] or 1

	-- Ensure structure exists
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
	local colIdx = #cols + 1
	cols[colIdx] = { winId }

	return spaceId, colIdx
end

-- Find a slot that matches this frame (for tab/ID swap handling)
-- Returns slot info if found, nil otherwise
local function findSlotByFrame(frame, screenId, app)
	local tolerance = 10
	local spaceId = state.activeSpaceForScreen[screenId]
	local space = state.screens[screenId] and state.screens[screenId][spaceId]
	if not space then return nil end

	for colIdx, col in ipairs(space.cols) do
		for rowIdx, winId in ipairs(col) do
			local win = hs.window(winId)
			if not win then
				-- Dead window - this slot is available for replacement
				return {
					screenId = screenId,
					spaceId = spaceId,
					colIdx = colIdx,
					rowIdx = rowIdx,
					deadWindowId = winId
				}
			else
				-- Check if frame matches (same slot, different ID)
				local otherFrame = win:frame()
				if math.abs(frame.x - otherFrame.x) <= tolerance
					and math.abs(frame.y - otherFrame.y) <= tolerance
					and math.abs(frame.w - otherFrame.w) <= tolerance
					and math.abs(frame.h - otherFrame.h) <= tolerance then
					return {
						screenId = screenId,
						spaceId = spaceId,
						colIdx = colIdx,
						rowIdx = rowIdx,
						existingWindowId = winId
					}
				end
			end
		end
	end
	return nil
end

-- Replace a window ID in a slot
local function replaceWindowInSlot(slot, newWinId)
	local space = state.screens[slot.screenId][slot.spaceId]
	if not space then return false end

	local col = space.cols[slot.colIdx]
	if not col then return false end

	col[slot.rowIdx] = newWinId
	return true
end

------------------------------------------
-- Reconciliation
------------------------------------------

-- The core reconciliation function: syncs tracked state to actual window reality
function Events.reconcile()
	local reconcileStart = hs.timer.secondsSinceEpoch()

	-- Get all actual windows from macOS
	local allWindows = hs.window.allWindows()

	-- Build set of actual window IDs that should be managed
	local actualWindows = {}  -- windowId -> {win, screenId, app, frame}
	for _, win in ipairs(allWindows) do
		if win:isStandard() and win:isVisible() and not win:isFullScreen() then
			local screen = win:screen()
			local app = win:application()
			if screen and app then
				actualWindows[win:id()] = {
					win = win,
					screenId = screen:id(),
					app = app:name(),
					frame = win:frame(),
				}
			end
		end
	end

	-- Build set of tracked window IDs
	local trackedWindows = {}  -- windowId -> {screenId, spaceId, colIdx, rowIdx}
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			for colIdx, col in ipairs(space.cols) do
				for rowIdx, winId in ipairs(col) do
					trackedWindows[winId] = {
						screenId = screenId,
						spaceId = spaceId,
						colIdx = colIdx,
						rowIdx = rowIdx,
					}
				end
			end
		end
	end

	local removedAny = false
	local addedAny = false

	-- STEP 1: Remove windows that no longer exist
	for winId, pos in pairs(trackedWindows) do
		if not actualWindows[winId] then
			print("[reconcile] Removing dead window", winId)
			removeWindowFromState(winId, pos)
			removedAny = true
		end
	end

	-- STEP 2: Add windows that aren't tracked
	for winId, info in pairs(actualWindows) do
		if not trackedWindows[winId] then
			-- Try to match by frame (handles ID swaps from tabs/Chrome)
			local matchedSlot = findSlotByFrame(info.frame, info.screenId, info.app)

			if matchedSlot and matchedSlot.deadWindowId then
				-- Found a dead slot with matching frame - replace it
				print("[reconcile] Replacing dead window", matchedSlot.deadWindowId, "with", winId, "by frame match")
				replaceWindowInSlot(matchedSlot, winId)
			elseif matchedSlot and matchedSlot.existingWindowId and matchedSlot.existingWindowId ~= winId then
				-- Found existing window with same frame - likely tabs, consolidate
				print("[reconcile] Frame collision: window", winId, "matches frame of", matchedSlot.existingWindowId)
				-- Add as new row in same column (tabbed windows)
				local col = state.screens[matchedSlot.screenId][matchedSlot.spaceId].cols[matchedSlot.colIdx]
				table.insert(col, winId)
			else
				-- Genuinely new window
				print("[reconcile] Adding new window", winId, "app:", info.app)
				addWindowToNewColumn(winId, info.screenId)
				addedAny = true
			end
		end
	end

	-- Clean up the window stack
	cleanWindowStack()

	-- Retile if anything changed
	if removedAny or addedAny then
		retileAll()
	end

	local elapsed = (hs.timer.secondsSinceEpoch() - reconcileStart) * 1000
	print(string.format("[reconcile] Completed in %.2fms (removed=%s, added=%s)", elapsed, tostring(removedAny), tostring(addedAny)))
end

-- Debounced reconciliation - waits for events to settle before reconciling
local function debouncedReconcile(delay)
	delay = delay or 0.05
	if reconcileTimer then
		reconcileTimer:stop()
	end
	reconcileTimer = hs.timer.doAfter(delay, function()
		reconcileTimer = nil
		Events.reconcile()
	end)
end

------------------------------------------
-- Debounced Focus Tracking
------------------------------------------

-- Commit focus to window stack after debounce settles
local function commitFocus()
	if not pendingFocusWinId then return end

	-- Only commit if this window is still actually focused
	local current = hs.window.frontmostWindow()
	if current and current:id() == pendingFocusWinId then
		print("[focus] Committing focus to stack:", pendingFocusWinId)
		addToWindowStack(current)
	else
		print("[focus] Skipping stale focus:", pendingFocusWinId)
	end
	pendingFocusWinId = nil
end

-- Schedule a focus commit with debouncing
local function scheduleFocusCommit(winId, delay)
	if suppressFocusCommit then
		return
	end

	delay = delay or 0.1
	pendingFocusWinId = winId

	if focusCommitTimer then
		focusCommitTimer:stop()
	end
	focusCommitTimer = hs.timer.doAfter(delay, function()
		focusCommitTimer = nil
		commitFocus()
	end)
end

-- Suppress focus commits temporarily (called before WM actions that manage stack)
function Events.suppressFocus()
	suppressFocusCommit = true
	if focusCommitTimer then
		focusCommitTimer:stop()
		focusCommitTimer = nil
	end
	pendingFocusWinId = nil
end

-- Re-enable focus commits (called after WM action completes)
function Events.resumeFocus()
	suppressFocusCommit = false
end

function Events.stop()
	if reconcileTimer then
		reconcileTimer:stop()
		reconcileTimer = nil
	end
	if focusCommitTimer then
		focusCommitTimer:stop()
		focusCommitTimer = nil
	end
	if windowWatcher then
		print("[Events] Stopping window watcher")
		windowWatcher:unsubscribeAll()
		windowWatcher = nil
	end
end

------------------------------------------
-- Initialization
------------------------------------------

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
	-- Uses debounced focus tracking to filter spurious focus events
	windowWatcher:subscribe(hs.window.filter.windowFocused, function(win, appName, event)
		local winId = win:id()
		print("[windowFocused]", win:title(), winId)

		-- Clear urgency for focused window (immediate)
		if state.urgentWindows[winId] then
			clearWindowUrgent(winId)
		end

		-- Check for space switching (immediate)
		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if screenId and spaceId then
			if state.activeSpaceForScreen[screenId] ~= spaceId then
				local oldSpaceId = state.activeSpaceForScreen[screenId]
				state.activeSpaceForScreen[screenId] = spaceId
				moveSpaceWindowsOffscreen(screenId, oldSpaceId)
				retile(screenId, spaceId)
				updateMenubar()
			end
			bringIntoView(win)
		else
			-- Window not tracked - trigger reconciliation
			debouncedReconcile()
		end

		-- Schedule debounced focus commit to window stack
		-- This filters out rapid focus changes during create/destroy cycles
		scheduleFocusCommit(winId)
	end)
	profile("subscribe windowFocused")

	-- Window created handler - just trigger reconciliation
	windowWatcher:subscribe(hs.window.filter.windowCreated, function(win, appName, event)
		print("[windowCreated]", win:title(), win:id())
		debouncedReconcile()
	end)
	profile("subscribe windowCreated")

	-- Window destroyed handler - just trigger reconciliation
	windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(win, appName, event)
		print("[windowDestroyed]", win:title(), win:id())
		debouncedReconcile()
	end)
	profile("subscribe windowDestroyed")

	-- Fullscreen/unfullscreen handler
	windowWatcher:subscribe(
		{ hs.window.filter.windowFullscreened, hs.window.filter.windowUnfullscreened },
		function(win, appName, event)
			debouncedReconcile()
		end
	)
	profile("subscribe fullscreen")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[Events] Module initialized - TOTAL: %.2fms", totalTime))
end

return Events
