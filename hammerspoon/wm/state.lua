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
    windowStackIndex -> number

    -- Urgent windows tracking
    urgentWindows -> {
        [windowId] = true,
        ...
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
}

------------------------------------------
-- Private helpers
------------------------------------------

-- Get all currently open standard windows
local function getCurrentWindows()
	local windows = {}
	for _, app in ipairs(Application.runningApplications()) do
		for _, win in ipairs(app:allWindows()) do
			if win:isStandard() and win:isVisible() and not win:isFullScreen() then
				table.insert(windows, win)
			end
		end
	end
	return windows
end

-- Validate that a window ID still exists and is usable
local function isValidWindow(winId)
	local win = Window(winId)
	return win and win:isStandard() and win:isVisible()
end

------------------------------------------
-- Public API
------------------------------------------

-- Get the state table (for backwards compatibility)
function State.get()
	return state
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
function State.cleanSavedStateWindows(savedState)
	local deadWindows = {}
	for screenId, spaces in pairs(savedState.screens or {}) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				-- Clean each column, removing invalid window IDs
				for colIdx = #space.cols, 1, -1 do
					local col = space.cols[colIdx]
					for rowIdx = #col, 1, -1 do
						if not isValidWindow(col[rowIdx]) then
							table.insert(deadWindows, {
								winId = col[rowIdx],
								spaceId = spaceId,
								screenId = screenId
							})
							table.remove(col, rowIdx)
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

	if #deadWindows > 0 then
		print("[State] Found " .. #deadWindows .. " dead windows in saved state, will clean them up:")
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
function State.reconcileWindows(savedState)
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
	local currentWindows = getCurrentWindows()
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
	State.wm = wm
	print("[State] State module initialized")

	-- 0. Reset state to initial values (important for reinit)
	State.reset()

	-- 1. Load saved state
	local savedState = State.load()

	-- 2. Restore non-window state
	state.windowStack = savedState.windowStack or state.windowStack
	state.windowStackIndex = savedState.windowStackIndex or state.windowStackIndex
	state.fullscreenOriginalWidth = savedState.fullscreenOriginalWidth or state.fullscreenOriginalWidth
	state.urgentWindows = savedState.urgentWindows or state.urgentWindows
	state.activeSpaceForScreen = savedState.activeSpaceForScreen or state.activeSpaceForScreen
	state.startXForScreenAndSpace = savedState.startXForScreenAndSpace or state.startXForScreenAndSpace

	-- 3. Clean invalid window IDs from saved state
	State.cleanSavedStateWindows(savedState)

	-- 4. Handle disconnected monitors
	State.migrateDisconnectedScreens(savedState)

	-- 5. Initialize screen structures
	State.initializeScreenStructures(savedState)

	-- 6. Reconcile current windows with saved state
	State.reconcileWindows(savedState)

	return savedState
end

return State
