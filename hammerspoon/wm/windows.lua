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
function Windows.cleanWindowStack()
	for i = #state.windowStack, 1, -1 do
		local id = state.windowStack[i]
		local win = _windows[id] or Window(id)
		if not win or not win:isStandard() or not win:isVisible() then
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

-- Update z-order of windows based on focus
function Windows.updateZOrder(cols, focusedWindowId)
	if not cols or #cols == 0 or not focusedWindowId then
		return
	end

	local totalWindowCount = #flatten(cols)
	local _, _, focusedColIdx = Windows.locateWindow(focusedWindowId)
	if not focusedColIdx then
		return
	end

	-- Build desired front-to-back order
	local ordered = {}

	-- Helper to append all windows from a column (optionally skipping one)
	local function appendColumn(colIdx, skipId)
		local col = cols[colIdx]
		if not col then
			return
		end
		for _, id in ipairs(col) do
			if id ~= skipId then
				table.insert(ordered, id)
			end
		end
	end

	-- 1. Focused window
	table.insert(ordered, focusedWindowId)

	-- 2. Other rows in the same column
	appendColumn(focusedColIdx, focusedWindowId)

	-- 3. Columns farther from focus: left-1, right-1, left-2, right-2, …
	local offset = 1
	while #ordered < totalWindowCount do
		local leftIdx = focusedColIdx - offset
		local rightIdx = focusedColIdx + offset
		if leftIdx >= 1 then
			appendColumn(leftIdx)
		end
		if rightIdx <= #cols then
			appendColumn(rightIdx)
		end
		offset = offset + 1
	end

	-- Current z-order for our tiled windows (front-to-back)
	local currentPos = {}
	do
		local wanted = {}
		for _, id in ipairs(ordered) do
			wanted[id] = true
		end

		local idx = 1
		for _, w in ipairs(hs.window.orderedWindows()) do
			local id = w:id()
			if wanted[id] then
				currentPos[id] = idx
				idx = idx + 1
			end
		end
	end

	-- Walk desired order back→front, raising only when needed
	local minFront = math.huge -- frontmost index seen so far
	for i = #ordered, 1, -1 do
		local id = ordered[i]
		local pos = currentPos[id] or math.huge

		-- If this window is currently *behind* something that should be
		-- behind it, lift it; otherwise leave it where it is.
		if pos > minFront then
			local w = Windows.getWindow(id)
			if w then
				w:raise()
			end
			minFront = 0 -- now frontmost
		else
			if pos < minFront then
				minFront = pos
			end
		end
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
