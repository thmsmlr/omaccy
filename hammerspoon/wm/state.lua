-- State module: Manages window manager state and persistence
local State = {}
State.__index = State

-- Module dependencies
local serpent = dofile(hs.configdir .. "/serpent.lua")
local Application <const> = hs.application
local Window <const> = hs.window
local Screen <const> = hs.screen
local Settings <const> = hs.settings

-- State schema
--[[
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
    },
    -- Index into the window stack (for navigating backwards/forwards)
    windowStackIndex -> number,

    -- Urgent windows tracking
    urgentWindows -> {
        [windowId] = true,
        ...
    },

    -- Height ratios for windows in multi-row columns
    -- Stored as proportions (0-1) that sum to 1 for each column
    columnHeightRatios -> {
        screenId -> {
            spaceId -> {
                colIdx -> { ratio1, ratio2, ... },  -- ratios matching window order
                ...
            }
        }
    }
}
]]--

-- The actual state (module-level variable)
local state = {
	screens = {},
	activeSpaceForScreen = {},
	windowStack = {},
	windowStackIndex = 1,
	startXForScreenAndSpace = {},
	fullscreenOriginalWidth = {},
	urgentWindows = {},
	columnHeightRatios = {},
	-- Focus mode: "center" (auto-center focused window), "edge" (snap to nearest edge)
	focusMode = "center",
	-- Floating window frames: windowId -> {x, y, w, h} for position persistence
	floatingFrames = {},
}

------------------------------------------
-- Private helpers
------------------------------------------

-- Get all currently open standard windows and build lookup table
-- Uses CGWindowList for fast enumeration, then only queries specific windows via AX API
-- Returns: windows list, validWindowIds set
local function getCurrentWindowsWithLookup()
	local windows = {}
	local validIds = {}

	-- Get all windows from CGWindowList (fast, no AX API blocking)
	local cgWindows = hs.window.list() or {}

	for _, cgWin in ipairs(cgWindows) do
		local winId = cgWin.kCGWindowNumber
		local isOnscreen = cgWin.kCGWindowIsOnscreen
		local layer = cgWin.kCGWindowLayer or 0

		-- Only process on-screen windows at layer 0 (standard windows)
		if isOnscreen and layer == 0 then
			-- Query the specific window via AX API to verify it's standard/visible
			-- This is targeted (one window at a time) rather than querying all apps
			local win = Window(winId)
			if win and win:isStandard() and win:isVisible() and not win:isFullScreen() then
				table.insert(windows, win)
				validIds[winId] = true
			end
		end
	end

	return windows, validIds
end

------------------------------------------
-- Public API
------------------------------------------

-- Get the state table (for backwards compatibility)
function State.get()
	return state
end

-- Fast reinit: Only verify existing windows and add new ones
-- Skips expensive per-window AX API checks by trusting CGWindowList
-- Returns: savedState for use by callers
function State.reinit(wm)
	local initStart = hs.timer.secondsSinceEpoch()
	local stepStart = initStart
	local function profile(label)
		local now = hs.timer.secondsSinceEpoch()
		local elapsed = (now - stepStart) * 1000
		print(string.format("[State.reinit profile] %s: %.2fms", label, elapsed))
		stepStart = now
	end

	State.wm = wm
	print("[State.reinit] Fast state reinit starting")

	-- 1. Load saved state
	local savedState = State.load()
	profile("load")

	-- 2. Get CGWindowList (fast, no AX API)
	local cgData = hs.window.list() or {}
	local validCGIds = {}
	for _, cgWin in ipairs(cgData) do
		if cgWin.kCGWindowIsOnscreen and (cgWin.kCGWindowLayer or 0) == 0 then
			validCGIds[cgWin.kCGWindowNumber] = true
		end
	end
	profile("CGWindowList")

	-- 3. Build set of tracked window IDs from saved state
	local trackedIds = {}
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for _, col in ipairs(space.cols) do
					for _, winId in ipairs(col) do
						trackedIds[winId] = true
					end
				end
			end
		end
	end
	profile("build tracked set")

	-- 4. Remove dead windows from saved state (not in CGWindowList)
	local deadCount = 0
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for colIdx = #space.cols, 1, -1 do
					local col = space.cols[colIdx]
					for rowIdx = #col, 1, -1 do
						local winId = col[rowIdx]
						if not validCGIds[winId] then
							table.remove(col, rowIdx)
							deadCount = deadCount + 1
						end
					end
					if #col == 0 then
						table.remove(space.cols, colIdx)
					end
				end
			end
		end
	end
	if deadCount > 0 then
		print(string.format("[State.reinit] Removed %d dead windows", deadCount))
	end
	profile("remove dead windows")

	-- 5. Restore non-window state
	state.windowStack = savedState.windowStack or {}
	state.windowStackIndex = savedState.windowStackIndex or 1
	state.fullscreenOriginalWidth = savedState.fullscreenOriginalWidth or {}
	state.urgentWindows = savedState.urgentWindows or {}
	state.activeSpaceForScreen = savedState.activeSpaceForScreen or {}
	state.startXForScreenAndSpace = savedState.startXForScreenAndSpace or {}
	state.columnHeightRatios = savedState.columnHeightRatios or {}
	profile("restore non-window state")

	-- 6. Initialize screen structures
	State.initializeScreenStructures(savedState)
	profile("initializeScreenStructures")

	-- 7. Place tracked windows back into state (fast, no AX API)
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols and state.screens[screenId] and state.screens[screenId][spaceId] then
				for colIdx, col in ipairs(space.cols) do
					for _, winId in ipairs(col) do
						if validCGIds[winId] then
							-- Window is valid, place it
							local cols = state.screens[screenId][spaceId].cols
							cols[colIdx] = cols[colIdx] or {}
							table.insert(cols[colIdx], winId)
						end
					end
				end
			end
		end
	end
	profile("place tracked windows")

	-- 8. Find and add new windows (only query AX API for genuinely new windows)
	local newCount = 0
	for winId, _ in pairs(validCGIds) do
		if not trackedIds[winId] then
			-- New window - need to verify via AX API (targeted query)
			local win = Window(winId)
			if win and win:isStandard() and win:isVisible() and not win:isFullScreen() then
				local screen = win:screen()
				if screen then
					local screenId = screen:id()
					local spaceId = state.activeSpaceForScreen[screenId] or 1
					if state.screens[screenId] and state.screens[screenId][spaceId] then
						table.insert(state.screens[screenId][spaceId].cols, { winId })
						newCount = newCount + 1
					end
				end
			end
		end
	end
	if newCount > 0 then
		print(string.format("[State.reinit] Added %d new windows", newCount))
	end
	profile("add new windows")

	-- 9. Clean up empty columns
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for colIdx = #space.cols, 1, -1 do
					if not space.cols[colIdx] or #space.cols[colIdx] == 0 then
						table.remove(space.cols, colIdx)
					end
				end
			end
		end
	end
	profile("cleanup empty columns")

	-- 10. Clean stale urgentWindows entries
	for winId, _ in pairs(state.urgentWindows) do
		if not validCGIds[winId] then
			state.urgentWindows[winId] = nil
		end
	end
	profile("clean urgentWindows")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[State.reinit] Complete - TOTAL: %.2fms", totalTime))

	return savedState
end

-- Reset state to initial values (for reinit)
function State.reset()
	print("[State] Resetting state to initial values")
	state.screens = {}
	state.activeSpaceForScreen = {}
	state.windowStack = {}
	state.windowStackIndex = 1
	state.startXForScreenAndSpace = {}
	state.fullscreenOriginalWidth = {}
	state.urgentWindows = {}
	state.columnHeightRatios = {}
end

-- Save current state to persistent storage
function State.save()
	Settings.set("wm_two_state", serpent.dump(state))
end

-- Load saved state from persistent storage
function State.load()
	local ok, savedState = serpent.load(Settings.get("wm_two_state") or "{ screens = {} }")
	if not ok then
		print("[State] Failed to load saved state, starting fresh")
		return { screens = {} }
	end
	return savedState
end

-- Clean invalid window IDs from saved state structure
-- validIds: set of currently valid window IDs (from Accessibility API)
-- Uses CGWindowList as a secondary check to avoid removing windows that are
-- temporarily inaccessible (e.g., due to modal dialogs)
function State.cleanSavedStateWindows(savedState, validIds)
	-- Build set of window IDs that exist at window server level (CGWindowList)
	-- This catches windows that are temporarily inaccessible to the Accessibility API
	local windowServerIds = {}
	for _, cgWin in ipairs(hs.window.list() or {}) do
		if cgWin.kCGWindowIsOnscreen then
			windowServerIds[cgWin.kCGWindowNumber] = cgWin.kCGWindowOwnerName
		end
	end

	local deadWindows = {}
	local skippedWindows = {}
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				-- Clean each column, removing invalid window IDs
				for colIdx = #space.cols, 1, -1 do
					local col = space.cols[colIdx]
					for rowIdx = #col, 1, -1 do
						local winId = col[rowIdx]
						if not validIds[winId] then
							-- Window not accessible via AX API
							if windowServerIds[winId] then
								-- BUT it still exists at window server level - don't remove
								table.insert(skippedWindows, {
									winId = winId,
									spaceId = spaceId,
									screenId = screenId,
									appName = windowServerIds[winId]
								})
							else
								-- Gone from BOTH APIs - truly dead, safe to remove
								table.insert(deadWindows, {
									winId = winId,
									spaceId = spaceId,
									screenId = screenId
								})
								table.remove(col, rowIdx)
							end
						end
					end
					-- Remove empty columns
					if #col == 0 then
						table.remove(space.cols, colIdx)
					end
				end
			end
		end
	end

	if #skippedWindows > 0 then
		print("[State] Skipped " .. #skippedWindows .. " windows (inaccessible to AX but exist in window server):")
		for _, info in ipairs(skippedWindows) do
			print("  - Window ID " .. info.winId .. " (" .. (info.appName or "unknown") .. ") in space '" .. tostring(info.spaceId) .. "'")
		end
	end

	if #deadWindows > 0 then
		print("[State] Found " .. #deadWindows .. " dead windows in saved state, cleaning up:")
		for _, info in ipairs(deadWindows) do
			print("  - Window ID " .. info.winId .. " in space '" .. tostring(info.spaceId) .. "' on screen " .. info.screenId)
		end
	end
end

-- Handle screens that have been disconnected - migrate their spaces to first available screen
function State.migrateDisconnectedScreens(savedState)
	local connectedScreens = {}
	local availableScreens = Screen.allScreens()

	for _, scr in ipairs(availableScreens) do
		connectedScreens[scr:id()] = true
	end

	local firstScreen = availableScreens[1]
	if not firstScreen then
		return
	end

	local targetScreenId = firstScreen:id()
	savedState.screens[targetScreenId] = savedState.screens[targetScreenId] or {}
	savedState.startXForScreenAndSpace = savedState.startXForScreenAndSpace or {}
	savedState.startXForScreenAndSpace[targetScreenId] = savedState.startXForScreenAndSpace[targetScreenId] or {}

	-- Find orphaned screens
	local orphanedScreenIds = {}
	for savedScreenId, _ in pairs(savedState.screens or {}) do
		if not connectedScreens[savedScreenId] then
			table.insert(orphanedScreenIds, savedScreenId)
		end
	end

	-- Migrate each orphaned screen's spaces
	for _, orphanId in ipairs(orphanedScreenIds) do
		local orphanSpaces = savedState.screens[orphanId]
		for spaceId, spaceData in pairs(orphanSpaces) do
			local destSpaceId = nil

			if type(spaceId) == "string" then
				-- Named space: preserve name or add suffix if collision
				if not savedState.screens[targetScreenId][spaceId] then
					destSpaceId = spaceId
				else
					local suffix = 2
					while savedState.screens[targetScreenId][spaceId .. "_" .. suffix] do
						suffix = suffix + 1
					end
					destSpaceId = spaceId .. "_" .. suffix
					print("[State] Named space collision: '" .. spaceId .. "' -> '" .. destSpaceId .. "'")
				end
			else
				-- Numbered space: find open slot
				for i = 1, 9 do
					local existing = savedState.screens[targetScreenId][i]
					if not existing or (#(existing.cols or {}) == 0) then
						destSpaceId = i
						break
					end
				end

				if not destSpaceId then
					destSpaceId = "space_" .. spaceId .. "_migrated"
					print("[State] No numbered slots, converting to named: " .. destSpaceId)
				end
			end

			if destSpaceId then
				savedState.screens[targetScreenId][destSpaceId] = spaceData
				if savedState.startXForScreenAndSpace[orphanId] and savedState.startXForScreenAndSpace[orphanId][spaceId] then
					savedState.startXForScreenAndSpace[targetScreenId][destSpaceId] = savedState.startXForScreenAndSpace[orphanId][spaceId]
				end
			end
		end

		savedState.screens[orphanId] = nil
		savedState.startXForScreenAndSpace[orphanId] = nil
	end
end

-- Initialize screen structures with empty spaces
function State.initializeScreenStructures(savedState)
	for _, screen in ipairs(Screen.allScreens()) do
		local screenId = screen:id()

		state.screens[screenId] = {}
		state.activeSpaceForScreen[screenId] = state.activeSpaceForScreen[screenId] or 1
		state.startXForScreenAndSpace[screenId] = state.startXForScreenAndSpace[screenId] or {}

		-- Initialize numbered spaces 1-9
		for i = 1, 9 do
			state.screens[screenId][i] = { cols = {}, floating = {} }
			state.startXForScreenAndSpace[screenId][i] = state.startXForScreenAndSpace[screenId][i] or 0
		end

		-- Restore any named spaces from saved state
		if savedState.screens[screenId] then
			for spaceId, spaceData in pairs(savedState.screens[screenId]) do
				if type(spaceId) == "string" then
					state.screens[screenId][spaceId] = { cols = {}, floating = {} }
					state.startXForScreenAndSpace[screenId][spaceId] = savedState.startXForScreenAndSpace[screenId] and savedState.startXForScreenAndSpace[screenId][spaceId] or 0
				end
			end
		end
	end
end

-- Reconcile current windows with saved placements
-- currentWindows: list of current window objects (pre-fetched)
function State.reconcileWindows(savedState, currentWindows)
	-- Build placement map from saved state
	local savedPlacements = {}
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for colIdx, col in ipairs(space.cols) do
					for rowIdx, winId in ipairs(col) do
						savedPlacements[winId] = {
							screenId = screenId,
							spaceId = spaceId,
							colIdx = colIdx,
							rowIdx = rowIdx,
						}
					end
				end
			end
		end
	end

	-- Process all current windows
	local placedWindows = {}

	-- First pass: place windows that have valid saved positions
	for _, win in ipairs(currentWindows) do
		local winId = win:id()
		local placement = savedPlacements[winId]

		if placement then
			local screenId = placement.screenId
			local spaceId = placement.spaceId

			-- Check if the screen and space still exist
			if state.screens[screenId] and state.screens[screenId][spaceId] then
				-- Place in saved position
				local cols = state.screens[screenId][spaceId].cols
				cols[placement.colIdx] = cols[placement.colIdx] or {}
				table.insert(cols[placement.colIdx], winId)
				placedWindows[winId] = true

				print("[State] Restored window " .. winId .. " to space " .. tostring(spaceId))
			end
		end
	end

	-- Second pass: place windows without saved positions in space 1 of their current screen
	for _, win in ipairs(currentWindows) do
		local winId = win:id()
		if not placedWindows[winId] then
			local screen = win:screen()
			local screenId = screen and screen:id() or Screen.mainScreen():id()
			local spaceId = 1 -- Always place new windows in space 1

			local cols = state.screens[screenId][spaceId].cols
			table.insert(cols, { winId })

			print("[State] Placed new window " .. winId .. " in space 1")
		end
	end

	-- Clean up: remove empty columns and compact
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				-- Remove empty columns (including nil entries in sparse arrays)
				for colIdx = #space.cols, 1, -1 do
					if not space.cols[colIdx] or #space.cols[colIdx] == 0 then
						table.remove(space.cols, colIdx)
					end
				end
			end
		end
	end
end

-- Initialize the state module (called during WM init)
function State.init(wm)
	local initStart = hs.timer.secondsSinceEpoch()
	local stepStart = initStart
	local function profile(label)
		local now = hs.timer.secondsSinceEpoch()
		local elapsed = (now - stepStart) * 1000
		print(string.format("[State profile] %s: %.2fms", label, elapsed))
		stepStart = now
	end

	State.wm = wm
	print("[State] State module initialized")

	-- 0. Reset state to initial values (important for reinit)
	State.reset()
	profile("reset")

	-- 1. Load saved state
	local savedState = State.load()
	profile("load")

	-- 2. Restore non-window state
	state.windowStack = savedState.windowStack or state.windowStack
	state.windowStackIndex = savedState.windowStackIndex or state.windowStackIndex
	state.fullscreenOriginalWidth = savedState.fullscreenOriginalWidth or state.fullscreenOriginalWidth
	state.urgentWindows = savedState.urgentWindows or state.urgentWindows
	state.activeSpaceForScreen = savedState.activeSpaceForScreen or state.activeSpaceForScreen
	state.startXForScreenAndSpace = savedState.startXForScreenAndSpace or state.startXForScreenAndSpace
	state.columnHeightRatios = savedState.columnHeightRatios or state.columnHeightRatios
	state.focusMode = savedState.focusMode or state.focusMode
	state.floatingFrames = savedState.floatingFrames or state.floatingFrames
	profile("restore non-window state")

	-- 2a. Get all current windows once (expensive operation)
	local currentWindows, validIds = getCurrentWindowsWithLookup()
	profile("getCurrentWindowsWithLookup")

	-- 2b. Clean stale urgentWindows entries
	for winId, _ in pairs(state.urgentWindows) do
		if not validIds[winId] then
			print("[State] Removing stale urgent window: " .. winId)
			state.urgentWindows[winId] = nil
		end
	end

	-- 3. Clean invalid window IDs from saved state (using pre-built lookup)
	State.cleanSavedStateWindows(savedState, validIds)
	profile("cleanSavedStateWindows")

	-- 4. Handle disconnected monitors
	State.migrateDisconnectedScreens(savedState)
	profile("migrateDisconnectedScreens")

	-- 5. Initialize screen structures
	State.initializeScreenStructures(savedState)
	profile("initializeScreenStructures")

	-- 6. Reconcile current windows with saved state (using pre-fetched windows)
	State.reconcileWindows(savedState, currentWindows)
	profile("reconcileWindows")

	local totalTime = (hs.timer.secondsSinceEpoch() - initStart) * 1000
	print(string.format("[State] Init complete - TOTAL: %.2fms", totalTime))

	return savedState
end

return State
