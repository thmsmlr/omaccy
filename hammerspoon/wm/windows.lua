-- Windows module: Manages window utilities and operations
local Windows = {}
Windows.__index = Windows

-- Module dependencies
local Window <const> = hs.window
local Timer <const> = hs.timer
local Mouse <const> = hs.mouse

-- Window cache (module-level variable)
local _windows = {}

-- Reference to WM module (set during init)
local wm = nil
local state = nil

-- Forward declarations for callbacks
local updateMenubar
local buildCommandPaletteChoices

------------------------------------------
-- Private helpers
------------------------------------------

local function flatten(tbl)
	local result = {}
	for _, sublist in ipairs(tbl) do
		for _, v in ipairs(sublist) do
			table.insert(result, v)
		end
	end
	return result
end

-- Returns the index in `xs` of the value from `xs` that appears earliest in `ys`, or nil if none found.
-- That is, among all values in `xs` that are present in `ys`, returns the index in `xs` whose value appears at the lowest index in `ys`.
local function earliestIndexInList(xs, ys)
	local minYIdx = math.huge
	local minXIdx = nil
	local yIndex = {}
	for i, y in ipairs(ys) do
		yIndex[y] = i
	end
	for i, x in ipairs(xs) do
		local idx = yIndex[x]
		if idx and idx < minYIdx then
			minYIdx = idx
			minXIdx = i
		end
	end
	return minXIdx
end

------------------------------------------
-- Public API
------------------------------------------

-- Get or create a cached window object
function Windows.getWindow(winId)
	if _windows[winId] then
		return _windows[winId]
	end
	_windows[winId] = Window(winId)
	return _windows[winId]
end

-- Removes invalid or closed windows from the window stack
-- Uses CGWindowList for fast verification instead of expensive Accessibility API calls
function Windows.cleanWindowStack()
	-- Build set of valid window IDs from CGWindowList (fast, no AX API)
	-- This avoids removing windows that are temporarily inaccessible due to modal dialogs
	local validWindowIds = {}
	for _, cgWin in ipairs(hs.window.list() or {}) do
		if cgWin.kCGWindowIsOnscreen then
			validWindowIds[cgWin.kCGWindowNumber] = true
		end
	end

	for i = #state.windowStack, 1, -1 do
		local id = state.windowStack[i]
		if not validWindowIds[id] then
			-- Window no longer exists at window server level - truly gone
			table.remove(state.windowStack, i)
		end
	end
	-- Clamp the active index to the valid range
	if state.windowStackIndex > #state.windowStack then
		state.windowStackIndex = #state.windowStack
	end
	if state.windowStackIndex < 1 then
		state.windowStackIndex = 1
	end
end

-- Focus a window with retry logic
function Windows.focusWindow(w, callback)
	local function waitForFocus(attempts)
		if attempts == 0 then
			return
		end
		local app = w:application()
		w:raise() -- Only raise this specific window, not all app windows
		local axApp = hs.axuielement.applicationElement(app)
		local wasEnhanced = axApp.AXEnhancedUserInterface
		if Window.focusedWindow() ~= w then
			Timer.doAfter(0.001, function()
				w:focus()
				Timer.doAfter(0.001, function()
					waitForFocus(attempts - 1)
				end)
			end)
		else
			if wasEnhanced then
				axApp.AXEnhancedUserInterface = true
			end

			-- Clear urgency for focused window
			local winId = w:id()
			if state.urgentWindows[winId] then
				state.urgentWindows[winId] = nil
				print("[urgency] Cleared urgency for window " .. winId)
				if updateMenubar then
					updateMenubar()
				end

				-- Refresh command palette if it's visible
				if wm._commandPalette and wm._commandPalette:isVisible() and buildCommandPaletteChoices then
					local currentQuery = wm._commandPalette:query()
					local choices = buildCommandPaletteChoices(currentQuery)
					wm._commandPalette:choices(choices)
				end
			end

			-- Update Z-order to ensure all windows in the focused column are properly raised
			local screenId, spaceId = Windows.locateWindow(winId)
			if screenId and spaceId and state.screens[screenId] and state.screens[screenId][spaceId] then
				local cols = state.screens[screenId][spaceId].cols
				Windows.updateZOrder(cols, winId)
			end

			if callback then
				callback()
			end
		end
	end

	waitForFocus(10)
end

-- Locate a window in the state structure
function Windows.locateWindow(windowId)
	local currentWindow = Windows.getWindow(windowId)
	local currentWindowId = windowId or currentWindow:id()
	local foundScreenId, foundSpaceId, foundColIdx, foundRowIdx = nil, nil, nil, nil

	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			for colIdx, col in ipairs(space.cols) do
				for rowIdx, winId in ipairs(col) do
					if winId == currentWindowId then
						foundScreenId = screenId
						foundSpaceId = spaceId
						foundColIdx = colIdx
						foundRowIdx = rowIdx
						break
					end
				end
				if foundScreenId then
					break
				end
			end
			if foundScreenId then
				break
			end
		end
		if foundScreenId then
			break
		end
	end

	return foundScreenId, foundSpaceId, foundColIdx, foundRowIdx
end

-- Update z-order of windows using coverflow-style algorithm.
-- Only raises windows when they overlap with a window farther from focus
-- that is incorrectly in front. This minimizes unnecessary raise() calls.
function Windows.updateZOrder(cols, focusedWindowId)
	if not cols or #cols == 0 or not focusedWindowId then
		return
	end

	local _, _, focusedColIdx = Windows.locateWindow(focusedWindowId)
	if not focusedColIdx then
		return
	end

	-- Build a flat list of window info for all tiled windows
	local allWindows = {}
	for colIdx, col in ipairs(cols) do
		for _, winId in ipairs(col) do
			local win = Windows.getWindow(winId)
			if win then
				table.insert(allWindows, {
					id = winId,
					colIdx = colIdx,
					frame = win:frame(),
					win = win,
				})
			end
		end
	end

	if #allWindows == 0 then
		return
	end

	-- Helper: check if two frames overlap horizontally
	local function framesOverlap(f1, f2)
		return f1.x < (f2.x + f2.w) and (f1.x + f1.w) > f2.x
	end

	-- Column distance from focus (0 = focused column)
	local function colDistance(colIdx)
		return math.abs(colIdx - focusedColIdx)
	end

	-- Get current z-order positions (lower = more in front)
	local currentZPos = {}
	do
		local idx = 1
		for _, w in ipairs(hs.window.orderedWindows()) do
			currentZPos[w:id()] = idx
			idx = idx + 1
		end
	end

	-- Find windows that need raising:
	-- A window needs raising if there exists an overlapping window
	-- that is farther from focus but currently in front of it
	local needsRaise = {}

	for i, winA in ipairs(allWindows) do
		local distA = colDistance(winA.colIdx)
		local posA = currentZPos[winA.id] or math.huge

		for j, winB in ipairs(allWindows) do
			if i ~= j and framesOverlap(winA.frame, winB.frame) then
				local distB = colDistance(winB.colIdx)
				local posB = currentZPos[winB.id] or math.huge

				-- If A should be in front (closer to focus) but B is currently in front
				if distA < distB and posA > posB then
					needsRaise[winA.id] = {
						win = winA.win,
						dist = distA,
					}
				end
				-- Tie-breaker: same distance, prefer left column (lower colIdx)
				if distA == distB and winA.colIdx < winB.colIdx and posA > posB then
					needsRaise[winA.id] = {
						win = winA.win,
						dist = distA,
					}
				end
			end
		end
	end

	-- Raise windows that need it, from farthest to closest
	-- (so closer windows end up on top after all raises complete)
	local toRaise = {}
	for id, info in pairs(needsRaise) do
		table.insert(toRaise, { id = id, win = info.win, dist = info.dist })
	end
	table.sort(toRaise, function(a, b)
		return a.dist > b.dist
	end)

	for _, item in ipairs(toRaise) do
		item.win:raise()
	end
end

-- Check if two frames differ by more than tolerance
function Windows.framesDiffer(f1, f2, tolerance)
	tolerance = tolerance or 1
	return math.abs(f1.x - f2.x) > tolerance
		or math.abs(f1.y - f2.y) > tolerance
		or math.abs(f1.w - f2.w) > tolerance
		or math.abs(f1.h - f2.h) > tolerance
end

-- Center mouse in window
function Windows.centerMouseInWindow(win)
	if not win then
		return
	end
	local f = win:frame()
	Mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + f.h / 2 })
end

-- Get index of window in stack
function Windows.getWindowStackIndex(winId)
	for i, v in ipairs(state.windowStack) do
		if v == winId then
			return i
		end
	end
end

-- Add window to stack
function Windows.addToWindowStack(win)
	if not win or not win:id() then
		return
	end
	local id = win:id()
	if state.windowStackIndex and state.windowStackIndex > 1 then
		for i = state.windowStackIndex - 1, 1, -1 do
			table.remove(state.windowStack, i)
		end
		state.windowStackIndex = 1
	end
	local idx = Windows.getWindowStackIndex(id)
	if idx then
		table.remove(state.windowStack, idx)
	end
	table.insert(state.windowStack, 1, id)
	if #state.windowStack > 50 then
		table.remove(state.windowStack)
	end

	-- print("--- Add to window stack ---")
	-- for i, id in ipairs(state.windowStack) do
	--     local w = Windows.getWindow(id)
	--     local title = w and w:title() or tostring(id)
	--     local marker = (i == state.windowStackIndex) and ">" or " "
	--     print(string.format("%s [%d] %s", marker, i, title))
	-- end
end

-- Utility: Flatten nested tables
function Windows.flatten(tbl)
	return flatten(tbl)
end

-- Utility: Get earliest index in list
function Windows.earliestIndexInList(xs, ys)
	return earliestIndexInList(xs, ys)
end

-- Initialize the windows module (called during WM init)
function Windows.init(wmModule)
	wm = wmModule
	state = wmModule.State.get()

	-- Set callback references
	updateMenubar = _G.updateMenubar
	buildCommandPaletteChoices = _G.buildCommandPaletteChoices

	print("[Windows] Windows module initialized")
end

-- Set UI callback references (called after UI is set up)
function Windows.setUICallbacks(updateMenubarFn, buildChoicesFn)
	updateMenubar = updateMenubarFn
	buildCommandPaletteChoices = buildChoicesFn
end

return Windows
