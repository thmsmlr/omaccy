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
local suppressFocusHandler = false -- flag to suppress entire focus handler during navigation

-- Fullscreen transition handling
-- When a window enters/exits native fullscreen, macOS fires a storm of events
-- that can corrupt state. We use a cooldown period to let the transition settle.
local fullscreenCooldownUntil = 0  -- timestamp when cooldown ends
local FULLSCREEN_COOLDOWN_MS = 500 -- how long to wait after fullscreen events

------------------------------------------
-- Helper functions
------------------------------------------

-- Remove a window from state given its position
-- Enhanced with position validation to catch state corruption early
local function removeWindowFromState(winId, pos)
	local space = state.screens[pos.screenId] and state.screens[pos.screenId][pos.spaceId]
	if not space then
		print(string.format("[removeWindowFromState] WARN: space doesn't exist: screen=%s, space=%s",
			tostring(pos.screenId), tostring(pos.spaceId)))
		return false
	end

	local col = space.cols[pos.colIdx]
	if not col then
		print(string.format("[removeWindowFromState] WARN: column doesn't exist: colIdx=%d",
			pos.colIdx))
		return false
	end

	-- Validate window is at expected position
	local foundAtExpected = (col[pos.rowIdx] == winId)
	if not foundAtExpected then
		print(string.format("[removeWindowFromState] WARN: window %d not at expected position (col=%d, row=%d), searching...",
			winId, pos.colIdx, pos.rowIdx))
	end

	-- Remove window from column (search in case position was stale)
	local removed = false
	for i = #col, 1, -1 do
		if col[i] == winId then
			table.remove(col, i)
			removed = true
			break
		end
	end

	if not removed then
		print(string.format("[removeWindowFromState] WARN: window %d not found in column %d",
			winId, pos.colIdx))
		return false
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

-- Check if two frames match within tolerance
local function framesMatch(f1, f2, tolerance)
	tolerance = tolerance or 10
	return math.abs(f1.x - f2.x) <= tolerance
		and math.abs(f1.y - f2.y) <= tolerance
		and math.abs(f1.w - f2.w) <= tolerance
		and math.abs(f1.h - f2.h) <= tolerance
end

-- Find a slot that matches this frame across ALL spaces (not just active)
-- This is critical for handling Chrome tab operations and window ID swaps
-- that happen on non-active spaces.
--
-- Search order (prioritized):
--   1. Dead slots with matching frame on SAME screen (any space) - ID swap on same screen
--   2. Dead slots with matching frame on OTHER screens - ID swap across screens
--   3. Existing windows with matching frame on SAME screen - tabbed/stacked windows
--   4. Existing windows with matching frame on OTHER screens - cross-screen tabs
--
-- Returns: {screenId, spaceId, colIdx, rowIdx, deadWindowId?, existingWindowId?, matchType}
--          or nil if no match found
local function findSlotByFrame(frame, screenId, app)
	local tolerance = 10
	local deadSlots = {}      -- Collect dead slots with matching frames
	local existingSlots = {}  -- Collect existing windows with matching frames

	-- Search all screens and spaces
	for checkScreenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for colIdx, col in ipairs(space.cols) do
					for rowIdx, winId in ipairs(col) do
						local win = hs.window(winId)
						if not win then
							-- Dead window slot - check if frame would match
							-- We can't get frame of dead window, but we track it as available
							-- Priority: same screen > other screens
							table.insert(deadSlots, {
								screenId = checkScreenId,
								spaceId = spaceId,
								colIdx = colIdx,
								rowIdx = rowIdx,
								deadWindowId = winId,
								sameScreen = (checkScreenId == screenId),
							})
						else
							-- Live window - check frame match
							local otherFrame = win:frame()
							if framesMatch(frame, otherFrame, tolerance) then
								table.insert(existingSlots, {
									screenId = checkScreenId,
									spaceId = spaceId,
									colIdx = colIdx,
									rowIdx = rowIdx,
									existingWindowId = winId,
									sameScreen = (checkScreenId == screenId),
								})
							end
						end
					end
				end
			end
		end
	end

	-- Debug logging: show what we found
	if #deadSlots > 0 or #existingSlots > 0 then
		print(string.format("[findSlotByFrame] Looking for frame (%.0f,%.0f,%.0f,%.0f) on screen %s for %s",
			frame.x, frame.y, frame.w, frame.h, tostring(screenId), app or "unknown"))
		print(string.format("[findSlotByFrame] Found %d dead slots, %d existing matches", #deadSlots, #existingSlots))
		for i, slot in ipairs(deadSlots) do
			print(string.format("[findSlotByFrame]   dead[%d]: winId=%d space=%s sameScreen=%s",
				i, slot.deadWindowId, tostring(slot.spaceId), tostring(slot.sameScreen)))
		end
	end

	-- Priority 1: Dead slot on same screen (most likely ID swap scenario)
	for _, slot in ipairs(deadSlots) do
		if slot.sameScreen then
			slot.matchType = "deadSameScreen"
			return slot
		end
	end

	-- Priority 2: Dead slot on other screen
	for _, slot in ipairs(deadSlots) do
		if not slot.sameScreen then
			slot.matchType = "deadOtherScreen"
			return slot
		end
	end

	-- Priority 3: Existing window with matching frame on same screen (tabbed)
	for _, slot in ipairs(existingSlots) do
		if slot.sameScreen then
			slot.matchType = "tabbedSameScreen"
			return slot
		end
	end

	-- Priority 4: Existing window with matching frame on other screen
	for _, slot in ipairs(existingSlots) do
		if not slot.sameScreen then
			slot.matchType = "tabbedOtherScreen"
			return slot
		end
	end

	-- No match found - log this for debugging
	print(string.format("[findSlotByFrame] No match found for frame (%.0f,%.0f,%.0f,%.0f) screen=%s app=%s (searched %d dead, %d existing)",
		frame.x, frame.y, frame.w, frame.h, tostring(screenId), app or "unknown", #deadSlots, #existingSlots))

	return nil
end

-- Replace a window ID in a slot (also updates windowStack to preserve history)
local function replaceWindowInSlot(slot, newWinId)
	local space = state.screens[slot.screenId][slot.spaceId]
	if not space then return false end

	local col = space.cols[slot.colIdx]
	if not col then return false end

	local oldWinId = slot.deadWindowId
	col[slot.rowIdx] = newWinId

	-- Update windowStack: replace old ID with new ID to preserve stack position
	-- This handles ID swaps (Chrome reload, tab detach, etc.) without losing history
	if oldWinId then
		for i, wid in ipairs(state.windowStack) do
			if wid == oldWinId then
				state.windowStack[i] = newWinId
				break
			end
		end
	end

	return true
end

------------------------------------------
-- Reconciliation
------------------------------------------

-- The core reconciliation function: syncs tracked state to actual window reality
function Events.reconcile()
	-- Check if we're in a fullscreen transition cooldown
	local now = hs.timer.secondsSinceEpoch()
	if now < fullscreenCooldownUntil then
		local remaining = math.floor((fullscreenCooldownUntil - now) * 1000)
		print(string.format("[reconcile] Skipped - fullscreen transition cooldown (%dms remaining)", remaining))
		return
	end

	local reconcileStart = now

	-- Get all windows from CGWindowList (fast, no AX API blocking)
	-- This gives us window IDs, app names, frames, and z-order without blocking
	local cgData = Windows.getWindowsFromCGWindowList()
	local windowServerIds = cgData.validIds  -- windowId -> true
	local windowServerInfo = cgData.byId     -- windowId -> { id, appName, frame, layer, zIndex }

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

	-- Build set of actual window IDs that should be managed
	-- For windows already tracked: use CGWindowList data (fast)
	-- For new windows: query AX API only for that specific window (targeted, not all apps)
	local actualWindows = {}  -- windowId -> {win, screenId, app, frame}

	-- First, check tracked windows against CGWindowList
	for winId, pos in pairs(trackedWindows) do
		if windowServerIds[winId] then
			-- Window still exists at window server level
			local info = windowServerInfo[winId]
			if info then
				-- Use cached hs.window object for frame/screen info
				local win = Windows.getWindow(winId)
				if win then
					local screen = win:screen()
					if screen and not Windows.isLikelyFullscreen(info.frame, screen:id()) then
						actualWindows[winId] = {
							win = win,
							screenId = screen:id(),
							app = info.appName,
							frame = info.frame,
						}
					end
				end
			end
		end
	end

	-- Second, find NEW windows that aren't tracked yet
	-- Only query AX API for windows we don't already know about
	for winId, info in pairs(windowServerInfo) do
		if not trackedWindows[winId] and not actualWindows[winId] then
			-- New window - need to verify it's standard/visible via AX API
			-- But only query THIS specific window, not all windows
			local win = hs.window(winId)
			if win and win:isStandard() and win:isVisible() and not win:isFullScreen() then
				local screen = win:screen()
				local app = win:application()
				if screen and app then
					actualWindows[winId] = {
						win = win,
						screenId = screen:id(),
						app = app:name(),
						frame = win:frame(),
					}
				end
			end
		end
	end

	local removedAny = false
	local addedAny = false

	-- STEP 1: Remove windows that no longer exist
	-- IMPORTANT: Verify windows are truly gone using CGWindowList, not just inaccessible to AX API
	-- This prevents removing windows that are temporarily blocked by modal dialogs
	local removedWindows = {}  -- Track what we're removing for logging
	local skippedWindows = {}  -- Track windows we're NOT removing (still in window server)
	for winId, pos in pairs(trackedWindows) do
		if not actualWindows[winId] then
			-- Window not accessible via Accessibility API
			if windowServerIds[winId] then
				-- BUT it still exists at window server level!
				-- This means it's temporarily inaccessible (modal dialog, AXUnknown, etc.)
				local info = windowServerInfo[winId]
				skippedWindows[winId] = info and info.appName or "unknown"
			else
				-- Gone from BOTH APIs - truly destroyed, safe to remove
				print(string.format("[reconcile] Removing dead window %d from space=%s col=%d row=%d",
					winId, tostring(pos.spaceId), pos.colIdx, pos.rowIdx))
				removedWindows[winId] = pos
				removeWindowFromState(winId, pos)
				removedAny = true
			end
		end
	end

	-- Log skipped windows (temporarily inaccessible)
	local skippedCount = 0
	for _ in pairs(skippedWindows) do skippedCount = skippedCount + 1 end
	if skippedCount > 0 then
		print(string.format("[reconcile] Skipped %d windows (inaccessible to AX but exist in window server):", skippedCount))
		for winId, appName in pairs(skippedWindows) do
			print(string.format("[reconcile]   - window %d (%s)", winId, appName))
		end
	end

	-- Log summary of removals
	if removedAny then
		local count = 0
		for _ in pairs(removedWindows) do count = count + 1 end
		print(string.format("[reconcile] Removed %d windows total", count))
	end

	-- STEP 2: Add windows that aren't tracked
	-- KEY PRINCIPLE: Trust window IDs as canonical. Only use frame-matching for genuine ID swaps.
	for winId, info in pairs(actualWindows) do
		if not trackedWindows[winId] then
			-- Window ID not in state - try to match by frame (handles ID swaps from tabs/Chrome)
			-- Now searches ALL spaces, not just active space
			local matchedSlot = findSlotByFrame(info.frame, info.screenId, info.app)

			if matchedSlot and matchedSlot.deadWindowId then
				-- Found a dead slot - this is likely an ID swap (tab detach, window reload, etc.)
				-- The new window replaces the dead one in its ORIGINAL position (preserves space assignment)
				print(string.format("[reconcile] ID swap: replacing dead %d with %d (space=%s, match=%s)",
					matchedSlot.deadWindowId, winId, tostring(matchedSlot.spaceId), matchedSlot.matchType))
				replaceWindowInSlot(matchedSlot, winId)
				addedAny = true
			elseif matchedSlot and matchedSlot.existingWindowId and matchedSlot.existingWindowId ~= winId then
				-- Found existing window with same frame - likely tabbed/stacked windows
				print(string.format("[reconcile] Tabbed: window %d matches frame of %d (space=%s, match=%s)",
					winId, matchedSlot.existingWindowId, tostring(matchedSlot.spaceId), matchedSlot.matchType))
				-- Add as new row in same column
				local col = state.screens[matchedSlot.screenId][matchedSlot.spaceId].cols[matchedSlot.colIdx]
				table.insert(col, winId)
				addedAny = true
			else
				-- Genuinely new window - add to active space
				print("[reconcile] New window", winId, "app:", info.app)
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

-- Suppress focus handling temporarily (called before WM actions that manage stack/spaces)
-- This prevents focus events from interfering with programmatic navigation
function Events.suppressFocus()
	suppressFocusCommit = true
	suppressFocusHandler = true
	if focusCommitTimer then
		focusCommitTimer:stop()
		focusCommitTimer = nil
	end
	pendingFocusWinId = nil
end

-- Re-enable focus handling (called after WM action completes)
-- Uses a short delay to let async window focus events settle before resuming
local resumeFocusTimer = nil
function Events.resumeFocus()
	if resumeFocusTimer then
		resumeFocusTimer:stop()
	end
	resumeFocusTimer = hs.timer.doAfter(0.05, function()
		resumeFocusTimer = nil
		suppressFocusCommit = false
		suppressFocusHandler = false
	end)
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

		-- Clear urgency for focused window (immediate, even when suppressed)
		if state.urgentWindows[winId] then
			clearWindowUrgent(winId)
		end

		-- Skip space-switching and viewport logic when suppressed
		-- (during programmatic navigation like navigateStack)
		if suppressFocusHandler then
			print("[windowFocused] Suppressed - skipping space/viewport logic")
			return
		end

		-- Check for space switching (immediate)
		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if screenId and spaceId then
			print(string.format("[windowFocused] suppressed=%s - bringIntoView for %d", tostring(suppressFocusHandler), winId))
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
	-- IMPORTANT: We don't call reconcile here. Instead we:
	-- 1. Set a cooldown to prevent other events from triggering reconcile during the transition
	-- 2. Handle the fullscreen state change explicitly
	windowWatcher:subscribe(hs.window.filter.windowFullscreened, function(win, appName, event)
		local winId = win:id()
		print(string.format("[windowFullscreened] %s (id=%d) - setting cooldown", appName, winId))

		-- Set cooldown to prevent reconcile during the transition animation
		fullscreenCooldownUntil = hs.timer.secondsSinceEpoch() + (FULLSCREEN_COOLDOWN_MS / 1000)

		-- Remove window from tiling (it's now in native fullscreen)
		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if screenId and spaceId and colIdx and rowIdx then
			-- Save position for potential restoration later
			state.fullscreenSavedPositions = state.fullscreenSavedPositions or {}
			state.fullscreenSavedPositions[winId] = {
				screenId = screenId,
				spaceId = spaceId,
				colIdx = colIdx,
				rowIdx = rowIdx,
			}

			-- Remove from state
			local pos = { screenId = screenId, spaceId = spaceId, colIdx = colIdx, rowIdx = rowIdx }
			removeWindowFromState(winId, pos)
			print(string.format("[windowFullscreened] Removed window %d from tiling (was at col=%d, row=%d)", winId, colIdx, rowIdx))

			-- Retile the space to fill the gap
			retile(screenId, spaceId)
		end
	end)

	windowWatcher:subscribe(hs.window.filter.windowUnfullscreened, function(win, appName, event)
		local winId = win:id()
		print(string.format("[windowUnfullscreened] %s (id=%d) - setting cooldown", appName, winId))

		-- Set cooldown to prevent reconcile during the transition animation
		fullscreenCooldownUntil = hs.timer.secondsSinceEpoch() + (FULLSCREEN_COOLDOWN_MS / 1000)

		-- Schedule re-adding the window after the animation completes
		-- We use a timer to let macOS finish the unfullscreen animation
		hs.timer.doAfter(FULLSCREEN_COOLDOWN_MS / 1000, function()
			-- Check if window still exists and isn't already tracked
			local existingScreenId = locateWindow(winId)
			if existingScreenId then
				print(string.format("[windowUnfullscreened] Window %d already in state, skipping", winId))
				return
			end

			-- Try to restore to saved position
			local savedPos = state.fullscreenSavedPositions and state.fullscreenSavedPositions[winId]
			if savedPos and state.screens[savedPos.screenId] and state.screens[savedPos.screenId][savedPos.spaceId] then
				local cols = state.screens[savedPos.screenId][savedPos.spaceId].cols
				-- Insert at saved column position (or at end if column no longer exists)
				local targetColIdx = math.min(savedPos.colIdx, #cols + 1)
				if targetColIdx <= #cols and cols[targetColIdx] then
					-- Insert into existing column at saved row
					local targetRowIdx = math.min(savedPos.rowIdx, #cols[targetColIdx] + 1)
					table.insert(cols[targetColIdx], targetRowIdx, winId)
				else
					-- Create new column
					cols[targetColIdx] = { winId }
				end
				print(string.format("[windowUnfullscreened] Restored window %d to col=%d", winId, targetColIdx))
				retile(savedPos.screenId, savedPos.spaceId)
				state.fullscreenSavedPositions[winId] = nil
			else
				-- No saved position - let reconcile handle it on next event
				print(string.format("[windowUnfullscreened] No saved position for window %d, will reconcile later", winId))
				-- Clear cooldown so next event can trigger reconcile
				fullscreenCooldownUntil = 0
				debouncedReconcile()
			end
		end)
	end)
	profile("subscribe fullscreen")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[Events] Module initialized - TOTAL: %.2fms", totalTime))
end

return Events
