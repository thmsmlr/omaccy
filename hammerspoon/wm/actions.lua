--[[
Actions Module

Contains all public action methods for the window manager.
These are the methods that users interact with via hotkeys.

Actions include:
- Navigation: focusDirection, navigateStack, nextScreen
- Manipulation: moveDirection, slurp, barf
- Space operations: switchToSpace, createSpace, renameSpace
- Window operations: toggleFullscreen, resize*, centerWindow, closeFocusedWindow
- App launching: launchOrFocusApp
- Scrolling: scroll

Dependencies: state, windows, tiling, spaces, urgency, events
]]
--

local Actions = {}

-- Forward declarations for dependencies (set during init)
local WM
local state
local Windows
local Tiling
local Spaces
local Urgency
local Events

-- Local references to frequently used functions (set during init)
local getWindow
local addToWindowStack
local debouncedAddToWindowStack
local cleanWindowStack
local locateWindow
local focusWindow
local centerMouseInWindow
local flatten
local earliestIndexInList
local retile
local retileAll
local bringIntoView
local moveSpaceWindowsOffscreen
local getUrgentWindowsInSpace
local updateMenubar

-- Forward declaration for local helper
local centerWindowInView

-- Constants (will be set from WM during init)
local tileGap
local resizeStep
local scrollSpeed

------------------------------------------
-- Navigation Actions
------------------------------------------

function Actions.navigateStack(direction)
	-- Suppress focus commits so they don't reset our stack position
	Events.suppressFocus()

	if direction == "in" then
		state.windowStackIndex = state.windowStackIndex - 1
	end
	if direction == "out" then
		state.windowStackIndex = state.windowStackIndex + 1
	end
	if state.windowStackIndex < 1 then
		state.windowStackIndex = 1
	end
	if state.windowStackIndex > #state.windowStack then
		state.windowStackIndex = #state.windowStack
	end
	local winId = state.windowStack[state.windowStackIndex]
	if not winId then
		Events.resumeFocus()
		return
	end
	local win = getWindow(winId)
	if not win then
		Events.resumeFocus()
		return
	end

	local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
	if not screenId or not spaceId then
		Events.resumeFocus()
		return
	end
	local currentSpaceId = state.activeSpaceForScreen[screenId]
	local switchingSpaces = (spaceId ~= currentSpaceId)

	if switchingSpaces then
		-- Calculate correct startX BEFORE switching spaces
		local screenFrame = hs.screen(screenId):frame()

		-- Calculate total width before the target window in the stack
		local preWidth = 0
		for i = 1, colIdx - 1 do
			local preWinId = state.screens[screenId][spaceId].cols[i][1]
			local w = getWindow(preWinId)
			if w then
				preWidth = preWidth + w:frame().w + tileGap
			end
		end

		-- Center the target window on screen
		local targetX = (screenFrame.w - win:frame().w) / 2
		local newStartX = targetX - preWidth
		state.startXForScreenAndSpace[screenId][spaceId] = newStartX

		-- Switch spaces with zero animation to avoid windows flying across screen
		state.activeSpaceForScreen[screenId] = spaceId
		moveSpaceWindowsOffscreen(screenId, currentSpaceId)
		retile(screenId, spaceId, { duration = 0 })

		-- Update menubar to reflect space change
		updateMenubar()
	end

	focusWindow(win, function()
		centerWindowInView(win)
		centerMouseInWindow(win)
		Events.resumeFocus()
	end)
end

function Actions.focusDirection(direction)
	local focusedWindow = hs.window.focusedWindow()
	if not focusedWindow then
		return
	end
	local currentScreenId, currentSpace, currentColIdx, currentRowIdx = locateWindow(focusedWindow:id())

	if not currentColIdx then
		return
	end

	-- Suppress focus handling to prevent z-order updates from stealing focus
	Events.suppressFocus()

	local cols = state.screens[currentScreenId][currentSpace].cols

	-- Build set of valid window IDs from CGWindowList (cached for this function call)
	-- This is much faster than calling hs.window(winId) repeatedly in the loop below,
	-- and avoids issues with windows temporarily inaccessible due to modal dialogs
	local validWindowIds = {}
	for _, cgWin in ipairs(hs.window.list() or {}) do
		if cgWin.kCGWindowIsOnscreen then
			validWindowIds[cgWin.kCGWindowNumber] = true
		end
	end

	-- Helper to check if a window exists (uses cached CGWindowList)
	local function windowExists(winId)
		return validWindowIds[winId] == true
	end

	if direction == "left" or direction == "right" then
		local delta = (direction == "left") and -1 or 1
		local targetColIdx = currentColIdx + delta

		-- Keep searching in the direction until we find an existing window or hit bounds
		while targetColIdx >= 1 and targetColIdx <= #cols do
			local col = cols[targetColIdx]
			if col and #col > 0 then
				-- Find the best row (earliest in window stack, or first existing window)
				local targetRowIdx = earliestIndexInList(col, state.windowStack) or 1
				local targetWinId = col[targetRowIdx]

				-- Check if this window exists
				if windowExists(targetWinId) then
					local nextWindow = getWindow(targetWinId)
					focusWindow(nextWindow, function()
						debouncedAddToWindowStack(nextWindow)
						bringIntoView(nextWindow)
						centerMouseInWindow(nextWindow)
						Events.resumeFocus()
					end)
					return
				end

				-- Window doesn't exist, try other rows in this column
				for rowIdx, winId in ipairs(col) do
					if rowIdx ~= targetRowIdx and windowExists(winId) then
						local nextWindow = getWindow(winId)
						focusWindow(nextWindow, function()
							debouncedAddToWindowStack(nextWindow)
							bringIntoView(nextWindow)
							centerMouseInWindow(nextWindow)
							Events.resumeFocus()
						end)
						return
					end
				end
			end
			-- No valid window in this column, continue searching
			targetColIdx = targetColIdx + delta
		end
		-- No valid window found
		Events.resumeFocus()
		return
	end

	if direction == "down" then
		currentRowIdx = currentRowIdx + 1
	end
	if direction == "up" then
		currentRowIdx = currentRowIdx - 1
	end
	if currentRowIdx < 1 then
		Events.resumeFocus()
		return
	end
	if currentRowIdx > #cols[currentColIdx] then
		Events.resumeFocus()
		return
	end

	local targetWinId = cols[currentColIdx][currentRowIdx]
	if not windowExists(targetWinId) then
		-- For up/down, just skip if window doesn't exist
		Events.resumeFocus()
		return
	end

	local nextWindow = getWindow(targetWinId)
	if nextWindow then
		focusWindow(nextWindow, function()
			debouncedAddToWindowStack(nextWindow)
			bringIntoView(nextWindow)
			centerMouseInWindow(nextWindow)
			Events.resumeFocus()
		end)
	else
		Events.resumeFocus()
	end
end

function Actions.nextScreen()
	local currentScreen = hs.mouse.getCurrentScreen()
	local currentScreenId = currentScreen:id()
	local currentSpace = state.activeSpaceForScreen[currentScreenId]
	local nextScreen = currentScreen:next()
	local nextScreenId = nextScreen:id()
	local nextSpace = state.activeSpaceForScreen[nextScreenId]

	-- Focus the first window in the next screen's first column
	local candidateWindowIds = flatten(state.screens[nextScreenId][nextSpace].cols)
	local nextWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
	local nextWindowId = candidateWindowIds[nextWindowIdx]
	if nextWindowId then
		local nextWindow = getWindow(nextWindowId)
		nextWindow:focus()
		centerMouseInWindow(nextWindow)
	else
		-- Center the mouse in the next screen
		local screenFrame = hs.screen(nextScreenId):frame()
		local centerX = screenFrame.x + screenFrame.w / 2
		local centerY = screenFrame.y + screenFrame.h / 2
		hs.mouse.absolutePosition({ x = centerX, y = centerY })
	end
end

------------------------------------------
-- Manipulation Actions
------------------------------------------

function Actions.moveDirection(direction)
	local focusedWindow = hs.window.focusedWindow()
	if not focusedWindow then
		return
	end
	local currentScreenId, currentSpace, currentColIdx, _ = locateWindow(focusedWindow:id())
	local nextColIdx = nil

	if not currentColIdx then
		return
	end
	if direction == "left" then
		nextColIdx = currentColIdx - 1
	end
	if direction == "right" then
		nextColIdx = currentColIdx + 1
	end
	if not nextColIdx then
		return
	end
	if nextColIdx < 1 then
		return
	end
	if nextColIdx > #state.screens[currentScreenId][currentSpace].cols then
		return
	end

	state.screens[currentScreenId][currentSpace].cols[currentColIdx], state.screens[currentScreenId][currentSpace].cols[nextColIdx] =
		state.screens[currentScreenId][currentSpace].cols[nextColIdx],
		state.screens[currentScreenId][currentSpace].cols[currentColIdx]

	local nextWindow = getWindow(state.screens[currentScreenId][currentSpace].cols[nextColIdx][1])
	if nextWindow then
		bringIntoView(nextWindow)
		centerMouseInWindow(nextWindow)
	end
end

function Actions.moveWindowToNextScreen()
	local currentWindow = hs.window.focusedWindow()
	if not currentWindow then
		return
	end
	local currentWindowId = currentWindow:id()
	local currentScreenId, currentSpace, currentColIdx, currentRowIdx = locateWindow(currentWindowId)
	local nextScreenId = currentWindow:screen():next():id()
	local nextSpace = state.activeSpaceForScreen[nextScreenId]

	table.insert(state.screens[nextScreenId][nextSpace].cols, { currentWindowId })
	table.remove(state.screens[currentScreenId][currentSpace].cols[currentColIdx], currentRowIdx)
	local columnWasRemoved = false
	if #state.screens[currentScreenId][currentSpace].cols[currentColIdx] == 0 then
		table.remove(state.screens[currentScreenId][currentSpace].cols, currentColIdx)
		columnWasRemoved = true
	end

	-- Clear height ratios for source column
	if state.columnHeightRatios[currentScreenId] and state.columnHeightRatios[currentScreenId][currentSpace] then
		local spaceRatios = state.columnHeightRatios[currentScreenId][currentSpace]
		if columnWasRemoved then
			local maxIdx = 0
			for k in pairs(spaceRatios) do
				if k > maxIdx then maxIdx = k end
			end
			for i = currentColIdx, maxIdx do
				spaceRatios[i] = spaceRatios[i + 1]
			end
		else
			spaceRatios[currentColIdx] = nil
		end
	end

	retile(currentScreenId, currentSpace)
	retile(nextScreenId, nextSpace)
end

function Actions.slurp()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	if not screenId or not spaceId or not colIdx or not rowIdx then
		return
	end
	local cols = state.screens[screenId][spaceId].cols
	if colIdx >= #cols then
		return
	end -- No column to the right
	local rightCol = cols[colIdx + 1]
	if not rightCol or #rightCol == 0 then
		return
	end

	for i = 1, #rightCol do
		table.insert(cols[colIdx], rowIdx + i, rightCol[i])
	end

	-- Remove the right column
	table.remove(cols, colIdx + 1)

	-- Clear height ratios for affected column and shift remaining indices
	if state.columnHeightRatios[screenId] and state.columnHeightRatios[screenId][spaceId] then
		local spaceRatios = state.columnHeightRatios[screenId][spaceId]
		-- Clear the slurped column (now has different windows)
		spaceRatios[colIdx] = nil
		-- Shift ratios for columns after the removed one
		local maxIdx = 0
		for k in pairs(spaceRatios) do
			if k > maxIdx then maxIdx = k end
		end
		for i = colIdx + 1, maxIdx do
			spaceRatios[i] = spaceRatios[i + 1]
		end
		spaceRatios[maxIdx + 1] = nil
	end

	-- Make all windows in the slurped column have the same height
	local screenFrame = hs.screen(screenId):frame()
	local col = cols[colIdx]
	local n = #col
	if n > 0 then
		local colHeight = screenFrame.h - tileGap * (n - 1)
		local winHeight = math.floor(colHeight / n)
		local y = screenFrame.y
		for i = 1, n do
			local w = getWindow(col[i])
			if w then
				local f = w:frame()
				f.y = y
				f.h = winHeight
				w:setFrame(f)
				y = y + winHeight + tileGap
			end
		end
	end

	retile(screenId, spaceId)

	-- Update Z-order to raise all windows in the slurped column
	Windows.updateZOrder(cols, win:id())
end

function Actions.barf()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	if not screenId or not spaceId or not colIdx or not rowIdx then
		return
	end
	local cols = state.screens[screenId][spaceId].cols
	if #cols == 0 then
		return
	end
	if colIdx == #cols then
		cols[colIdx + 1] = {}
	end
	if #cols[colIdx] == 0 then
		return
	end
	if #cols[colIdx] == 1 then
		return
	end
	local removedWin = table.remove(cols[colIdx], #cols[colIdx])
	if not removedWin then
		return
	end
	table.insert(cols, colIdx + 1, { removedWin })

	-- Clear height ratios for affected columns and shift indices
	if state.columnHeightRatios[screenId] and state.columnHeightRatios[screenId][spaceId] then
		local spaceRatios = state.columnHeightRatios[screenId][spaceId]
		-- Clear the source column (lost a window)
		spaceRatios[colIdx] = nil
		-- Shift ratios for columns after the insertion point
		local maxIdx = 0
		for k in pairs(spaceRatios) do
			if k > maxIdx then maxIdx = k end
		end
		for i = maxIdx, colIdx + 1, -1 do
			spaceRatios[i + 1] = spaceRatios[i]
		end
		spaceRatios[colIdx + 1] = nil -- New column has single window
	end

	-- Make all windows in the affected columns have the same height
	local screenFrame = hs.screen(screenId):frame()
	for i = colIdx, colIdx + 1 do
		local col = cols[i]
		if col then
			local n = #col
			if n > 0 then
				local colHeight = screenFrame.h - tileGap * (n - 1)
				local winHeight = math.floor(colHeight / n)
				local y = screenFrame.y
				for j = 1, n do
					local w = getWindow(col[j])
					if w then
						local f = w:frame()
						f.y = y
						f.h = winHeight
						w:setFrame(f)
						y = y + winHeight + tileGap
					end
				end
			end
		end
	end

	retile(screenId, spaceId)
end

------------------------------------------
-- Space Operations
------------------------------------------

function Actions.switchToSpace(spaceId)
	local currentScreen = hs.mouse.getCurrentScreen()
	local screenId = currentScreen:id()

	local currentSpace = state.activeSpaceForScreen[screenId]
	if currentSpace == spaceId then
		return
	end

	state.activeSpaceForScreen[screenId] = spaceId

	-- 4-phase optimized approach: show new content first, cleanup in background
	-- Phase 1: Move ALL new space windows to their correct positions
	retile(screenId, spaceId, { duration = 0 })

	-- Phase 2: Raise visible windows to top (>75% visible)
	local screenFrame = hs.screen(screenId):frame()
	local screenLeft = screenFrame.x
	local screenRight = screenFrame.x + screenFrame.w

	for _, col in ipairs(state.screens[screenId][spaceId].cols) do
		for _, winId in ipairs(col) do
			local win = getWindow(winId)
			if win then
				local f = win:frame()
				local winLeft = f.x
				local winRight = f.x + f.w
				local visibleLeft = math.max(winLeft, screenLeft)
				local visibleRight = math.min(winRight, screenRight)
				local visibleWidth = math.max(0, visibleRight - visibleLeft)
				local percentVisible = visibleWidth / f.w

				if percentVisible > 0.75 then
					win:raise()
				end
			end
		end
	end

	-- Phase 3: Clear old visible windows
	moveSpaceWindowsOffscreen(screenId, currentSpace, { onlyVisible = true })

	-- Phase 4: Background cleanup - move ALL remaining old windows offscreen
	moveSpaceWindowsOffscreen(screenId, currentSpace)

	-- Update menubar to reflect space change
	updateMenubar()

	-- Check if there are urgent windows in this space
	local urgentWindowIds = getUrgentWindowsInSpace(screenId, spaceId)
	local candidateWindowIds = flatten(state.screens[screenId][spaceId].cols)
	local nextWindowId

	if #urgentWindowIds > 0 then
		-- Focus the first urgent window (by earliest in window stack)
		local urgentWindowIdx = earliestIndexInList(urgentWindowIds, state.windowStack)
		nextWindowId = urgentWindowIds[urgentWindowIdx] or urgentWindowIds[1]
	else
		-- No urgent windows, use normal logic (earliest from window stack)
		local nextWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
		nextWindowId = candidateWindowIds[nextWindowIdx] or candidateWindowIds[1]
	end

	if nextWindowId then
		local nextWindow = getWindow(nextWindowId)
		-- Bring window into view BEFORE focusing
		bringIntoView(nextWindow)

		focusWindow(nextWindow, function()
			addToWindowStack(nextWindow)
			centerMouseInWindow(nextWindow)
		end)
	end
end

function Actions.createSpace(spaceId, screenId)
	-- Default to current screen if not specified
	screenId = screenId or hs.mouse.getCurrentScreen():id()

	-- Initialize screen if needed
	state.screens[screenId] = state.screens[screenId] or {}
	state.startXForScreenAndSpace[screenId] = state.startXForScreenAndSpace[screenId] or {}

	-- Initialize space if it doesn't exist
	if not state.screens[screenId][spaceId] then
		state.screens[screenId][spaceId] = { cols = {}, floating = {} }
		state.startXForScreenAndSpace[screenId][spaceId] = 0
		print("[createSpace]", "Created space:", spaceId, "on screen:", screenId)
	end

	return spaceId
end

function Actions.renameSpace(screenId, oldSpaceId, newSpaceId)
	-- Validate inputs
	if not screenId or not oldSpaceId or not newSpaceId then
		print("[renameSpace] Error: missing required parameters")
		return
	end

	-- Check if old space exists
	if not state.screens[screenId] or not state.screens[screenId][oldSpaceId] then
		print("[renameSpace] Error: space", oldSpaceId, "does not exist on screen", screenId)
		return
	end

	-- Check if new space name already exists
	if state.screens[screenId][newSpaceId] then
		print("[renameSpace] Error: space", newSpaceId, "already exists on screen", screenId)
		return
	end

	-- Don't allow renaming numbered spaces (1-9)
	if type(oldSpaceId) == "number" and oldSpaceId >= 1 and oldSpaceId <= 9 then
		print("[renameSpace] Error: cannot rename numbered space", oldSpaceId)
		return
	end

	print("[renameSpace]", "Renaming space:", oldSpaceId, "->", newSpaceId, "on screen:", screenId)

	-- Move space data to new key
	state.screens[screenId][newSpaceId] = state.screens[screenId][oldSpaceId]
	state.screens[screenId][oldSpaceId] = nil

	-- Move startX data
	if state.startXForScreenAndSpace[screenId] then
		state.startXForScreenAndSpace[screenId][newSpaceId] = state.startXForScreenAndSpace[screenId][oldSpaceId] or 0
		state.startXForScreenAndSpace[screenId][oldSpaceId] = nil
	end

	-- Update activeSpaceForScreen if this was the active space
	if state.activeSpaceForScreen[screenId] == oldSpaceId then
		state.activeSpaceForScreen[screenId] = newSpaceId
	end

	-- Update menubar to reflect the rename
	updateMenubar()

	-- Save state
	WM.State.save()

	print("[renameSpace]", "Successfully renamed space to:", newSpaceId)
end

function Actions.moveFocusedWindowToSpace(spaceId)
	local win = hs.window.focusedWindow()
	if not win then
		return
	end

	local screenId, currentSpace, colIdx, rowIdx = locateWindow(win:id())
	if not screenId or not currentSpace or not colIdx or not rowIdx then
		return
	end
	if currentSpace == spaceId then
		Actions.switchToSpace(spaceId)
		return
	end

	local removedWin = table.remove(state.screens[screenId][currentSpace].cols[colIdx], rowIdx)
	local columnWasRemoved = false
	if #state.screens[screenId][currentSpace].cols[colIdx] == 0 then
		table.remove(state.screens[screenId][currentSpace].cols, colIdx)
		columnWasRemoved = true
	end

	-- Clear height ratios for source column
	if state.columnHeightRatios[screenId] and state.columnHeightRatios[screenId][currentSpace] then
		local spaceRatios = state.columnHeightRatios[screenId][currentSpace]
		if columnWasRemoved then
			local maxIdx = 0
			for k in pairs(spaceRatios) do
				if k > maxIdx then maxIdx = k end
			end
			for i = colIdx, maxIdx do
				spaceRatios[i] = spaceRatios[i + 1]
			end
		else
			spaceRatios[colIdx] = nil
		end
	end

	table.insert(state.screens[screenId][spaceId].cols, { removedWin })
	retile(screenId, currentSpace)
	Actions.switchToSpace(spaceId)
end

------------------------------------------
-- Window Operations
------------------------------------------

function Actions.toggleFullscreen()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end

	state.fullscreenOriginalWidth = state.fullscreenOriginalWidth or {}

	local winId = win:id()
	local frame = win:frame()
	local screenFrame = win:screen():frame()

	if state.fullscreenOriginalWidth[winId] then
		-- Restore original width
		frame.w = state.fullscreenOriginalWidth[winId]
		frame.x = screenFrame.x
		state.fullscreenOriginalWidth[winId] = nil
	else
		-- Save current width and expand
		state.fullscreenOriginalWidth[winId] = frame.w
		frame.x = screenFrame.x
		frame.w = screenFrame.w
	end

	win:setFrame(frame, 0)
	bringIntoView(win)

	-- Retile the space so other windows fill in gaps
	local screenId, spaceId = locateWindow(winId)
	if screenId and spaceId then
		retile(screenId, spaceId)
	end
end

-- Helper to center a specific window in the view
centerWindowInView = function(win)
	if not win then
		return
	end
	local screenId, spaceId, colIdx, _ = locateWindow(win:id())
	if not screenId or not spaceId or not colIdx then
		return
	end

	local screen = hs.screen(screenId)
	if not screen then
		return
	end
	local screenFrame = screen:frame()

	local preWidth = 0
	for i = 1, colIdx - 1 do
		local w = getWindow(state.screens[screenId][spaceId].cols[i][1])
		if w then
			preWidth = preWidth + w:frame().w + tileGap
		end
	end

	local targetX = (screenFrame.w - win:frame().w) / 2
	local startX = targetX - preWidth
	state.startXForScreenAndSpace[screenId][spaceId] = startX
	retile(screenId, spaceId)
end

function Actions.centerWindow()
	local win = hs.window.focusedWindow()
	centerWindowInView(win)
end

function Actions.resizeFocusedWindowHorizontally(delta)
	local win = hs.window.focusedWindow()
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	local col = state.screens[screenId][spaceId].cols[colIdx]
	local screenFrame = win:screen():frame()

	for _, winId in ipairs(col) do
		local w = getWindow(winId)
		if w then
			local f = w:frame()
			local screenRight = screenFrame.x + screenFrame.w
			local winRight = f.x + f.w
			local newWidth = math.max(100, f.w + delta)
			if winRight >= screenRight - 1 and delta > 0 then
				f.x = f.x - delta
			end
			f.w = newWidth
			w:_setFrame(f)
		end
	end

	-- Retile to reflow other columns based on new width
	retile(screenId, spaceId)
	bringIntoView(win)
end

function Actions.resizeFocusedWindowVertically(delta)
	local win = hs.window.focusedWindow()
	if not win or delta == 0 then
		return
	end

	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	if not (screenId and spaceId and colIdx and rowIdx) then
		return
	end

	local col = state.screens[screenId][spaceId].cols[colIdx]
	if not col or #col < 2 then
		return
	end

	local n = #col
	local screenFrame = hs.screen(screenId):frame()
	local minHeight = 50
	local totalColHeight = screenFrame.h - tileGap * (n - 1)

	-- Gather current heights
	local heights, othersTotal = {}, 0
	for i, winId in ipairs(col) do
		local h = getWindow(winId):frame().h
		heights[i] = h
		if i ~= rowIdx then
			othersTotal = othersTotal + h
		end
	end

	-- Clamp new height for the focused window
	local focusCurrent = heights[rowIdx]
	local focusNew = math.max(minHeight, math.min(focusCurrent + delta, totalColHeight - minHeight * (n - 1)))
	if focusNew == focusCurrent then
		return
	end

	-- Target total height for remaining windows
	local targetOthersTotal = totalColHeight - focusNew
	local scale = targetOthersTotal / othersTotal

	-- Compute new heights
	local newHeights, allocated = {}, 0
	for i, h in ipairs(heights) do
		if i == rowIdx then
			newHeights[i] = focusNew
		else
			local nh = math.max(minHeight, math.floor(h * scale))
			newHeights[i] = nh
			allocated = allocated + nh
		end
	end

	-- Distribute any leftover pixels
	local leftover = targetOthersTotal - allocated
	if leftover ~= 0 then
		local direction = leftover > 0 and 1 or -1
		leftover = math.abs(leftover)
		for i = 1, n do
			if i ~= rowIdx then
				newHeights[i] = newHeights[i] + direction
				leftover = leftover - 1
				if leftover == 0 then
					break
				end
			end
		end
	end

	-- Apply new frames
	local y = screenFrame.y
	for i, winId in ipairs(col) do
		local w = getWindow(winId)
		local f = w:frame()
		f.y = y
		f.h = newHeights[i]
		w:setFrame(f)
		y = y + f.h + tileGap
	end

	-- Save height ratios to state
	local ratios = {}
	for i, h in ipairs(newHeights) do
		ratios[i] = h / totalColHeight
	end

	-- Ensure nested tables exist
	state.columnHeightRatios[screenId] = state.columnHeightRatios[screenId] or {}
	state.columnHeightRatios[screenId][spaceId] = state.columnHeightRatios[screenId][spaceId] or {}
	state.columnHeightRatios[screenId][spaceId][colIdx] = ratios
end

function Actions.closeFocusedWindow()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	win:close()
	if not screenId or not spaceId or not colIdx or not rowIdx then
		return
	end
	if colIdx > 1 then
		colIdx = colIdx - 1
	end
	local nextWindowId = state.screens[screenId][spaceId].cols[colIdx][1]
	local nextWindow = getWindow(nextWindowId)
	focusWindow(nextWindow, function()
		addToWindowStack(nextWindow)
		bringIntoView(nextWindow)
		centerMouseInWindow(nextWindow)
	end)
end

------------------------------------------
-- Focus Mode
------------------------------------------

-- Get current focus mode
function Actions.getFocusMode()
	return state.focusMode or "center"
end

-- Set focus mode: "center" or "edge"
function Actions.setFocusMode(mode)
	if mode ~= "center" and mode ~= "edge" then
		print("[setFocusMode] Invalid mode:", mode)
		return
	end
	state.focusMode = mode
	print("[setFocusMode] Focus mode set to:", mode)
	updateMenubar()
end

-- Cycle through focus modes: center -> edge -> center
function Actions.cycleFocusMode()
	local current = state.focusMode or "center"
	local nextMode = (current == "center") and "edge" or "center"
	Actions.setFocusMode(nextMode)
end

------------------------------------------
-- Floating Windows
------------------------------------------

-- Check if a window is floating (in the floating layer, not tiled)
function Actions.isWindowFloating(winId)
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if space.floating then
				for _, floatWinId in ipairs(space.floating) do
					if floatWinId == winId then
						return true, screenId, spaceId
					end
				end
			end
		end
	end
	return false
end

-- Toggle floating state of focused window
function Actions.toggleFloating()
	local win = hs.window.focusedWindow()
	if not win then
		return
	end
	local winId = win:id()

	-- Check if already floating
	local isFloating, floatScreenId, floatSpaceId = Actions.isWindowFloating(winId)

	if isFloating then
		-- Move from floating to tiled
		print(string.format("[toggleFloating] Window %d: floating -> tiled", winId))

		-- Remove from floating array
		local floating = state.screens[floatScreenId][floatSpaceId].floating
		for i, fid in ipairs(floating) do
			if fid == winId then
				table.remove(floating, i)
				break
			end
		end

		-- Add to tiled columns (at the end)
		local cols = state.screens[floatScreenId][floatSpaceId].cols
		table.insert(cols, { winId })

		-- Retile to position the window
		retile(floatScreenId, floatSpaceId)
		bringIntoView(win)
	else
		-- Check if in tiled state
		local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
		if not screenId then
			print(string.format("[toggleFloating] Window %d not in state, cannot float", winId))
			return
		end

		print(string.format("[toggleFloating] Window %d: tiled -> floating", winId))

		-- Save current frame for floating position
		local frame = win:frame()
		state.floatingFrames[winId] = {
			x = frame.x,
			y = frame.y,
			w = frame.w,
			h = frame.h,
		}

		-- Remove from tiled columns
		local cols = state.screens[screenId][spaceId].cols
		local col = cols[colIdx]
		table.remove(col, rowIdx)

		-- Remove empty column
		if #col == 0 then
			table.remove(cols, colIdx)

			-- Shift height ratios
			if state.columnHeightRatios[screenId] and state.columnHeightRatios[screenId][spaceId] then
				local spaceRatios = state.columnHeightRatios[screenId][spaceId]
				local maxIdx = 0
				for k in pairs(spaceRatios) do
					if k > maxIdx then maxIdx = k end
				end
				for i = colIdx, maxIdx do
					spaceRatios[i] = spaceRatios[i + 1]
				end
			end
		else
			-- Clear height ratios for this column
			if state.columnHeightRatios[screenId] and state.columnHeightRatios[screenId][spaceId] then
				state.columnHeightRatios[screenId][spaceId][colIdx] = nil
			end
		end

		-- Add to floating array
		state.screens[screenId][spaceId].floating = state.screens[screenId][spaceId].floating or {}
		table.insert(state.screens[screenId][spaceId].floating, winId)

		-- Retile to fill the gap (this happens behind the floating window)
		retile(screenId, spaceId)

		-- Animate the window to "pop out" - shrink slightly and center
		-- This makes it visually clear that it's now floating
		local shrinkAmount = 40  -- pixels to shrink on each side
		local newFrame = {
			x = frame.x + shrinkAmount,
			y = frame.y + shrinkAmount,
			w = frame.w - (shrinkAmount * 2),
			h = frame.h - (shrinkAmount * 2),
		}

		-- Ensure minimum size
		newFrame.w = math.max(newFrame.w, 200)
		newFrame.h = math.max(newFrame.h, 150)

		-- Animate to the smaller frame
		win:setFrame(newFrame, 0.15)

		-- Update saved frame to the new size
		state.floatingFrames[winId] = {
			x = newFrame.x,
			y = newFrame.y,
			w = newFrame.w,
			h = newFrame.h,
		}

		-- Raise the floating window to top
		win:raise()
	end

	updateMenubar()
end

------------------------------------------
-- App Window Utilities (shared by launchOrFocusApp and URLs module)
------------------------------------------

-- Find a window of a specific app on a specific space
-- Uses CGWindowList to avoid slow app:allWindows() calls
function Actions.findAppWindowOnSpace(bundleID, targetScreenId, targetSpaceId)
	if not targetScreenId or not targetSpaceId then
		return nil
	end
	if not state.screens[targetScreenId] then
		return nil
	end
	local space = state.screens[targetScreenId][targetSpaceId]
	if not space then
		return nil
	end

	-- Collect all window IDs in this space
	local windowsInSpace = {}
	for _, col in ipairs(space.cols or {}) do
		for _, winId in ipairs(col) do
			windowsInSpace[winId] = true
		end
	end
	for _, winId in ipairs(space.floating or {}) do
		windowsInSpace[winId] = true
	end

	-- Get app name from bundleID
	local app = hs.application.get(bundleID)
	if not app then
		return nil
	end
	local appName = app:name()

	-- Get CGWindowList data to find windows by app name (fast)
	local cgData = Windows.getWindowsFromCGWindowList()
	local appWindowIds = cgData.byApp[appName] or {}

	-- Find a window of this app that's in the target space
	for _, winId in ipairs(appWindowIds) do
		if windowsInSpace[winId] then
			local win = getWindow(winId)
			if win and win:isStandard() then
				return win
			end
		end
	end
	return nil
end

-- Wait for a new window to appear (helper for launching)
-- Uses CGWindowList for fast enumeration, only queries AX API for new windows
local function waitForNewWindow(windowsBefore, bundleID, attempts, callback)
	if attempts <= 0 then
		print("[Actions] Gave up waiting for new window")
		return
	end

	-- Get current windows from CGWindowList (fast)
	local cgData = Windows.getWindowsFromCGWindowList()

	-- Look for new window IDs that weren't in windowsBefore
	for winId, info in pairs(cgData.byId) do
		if not windowsBefore[winId] then
			-- New window - verify it belongs to the target app via AX API (targeted query)
			local win = hs.window(winId)
			if win then
				local app = win:application()
				if app and app:bundleID() == bundleID then
					callback(win)
					return
				end
			end
		end
	end

	hs.timer.doAfter(0.025, function()
		waitForNewWindow(windowsBefore, bundleID, attempts - 1, callback)
	end)
end

-- Launch a new app window and place it on a specific space
-- opts.menuPath: menu items to create new window (e.g. {"File", "New Window"})
-- opts.launchCommand: fallback command if app not running
-- opts.colIdx: column index to place window (default 1)
-- opts.onWindowReady: callback(win) when window is placed
function Actions.launchAppWindowOnSpace(bundleID, targetScreenId, targetSpaceId, opts)
	opts = opts or {}
	local menuPath = opts.menuPath or { "File", "New Window" }
	local launchCommand = opts.launchCommand
	local colIdx = opts.colIdx or 1
	local onWindowReady = opts.onWindowReady

	local app = hs.application.get(bundleID)

	-- Track windows before launch using CGWindowList (fast)
	local windowsBefore = {}
	local cgData = Windows.getWindowsFromCGWindowList()
	for winId, _ in pairs(cgData.byId) do
		windowsBefore[winId] = true
	end

	-- Callback when new window appears
	local function handleNewWindow(win)
		print(string.format("[Actions] New window detected: %d", win:id()))
		-- Place in target space
		if targetScreenId and targetSpaceId and state.screens[targetScreenId] and state.screens[targetScreenId][targetSpaceId] then
			table.insert(state.screens[targetScreenId][targetSpaceId].cols, colIdx, { win:id() })
			retile(targetScreenId, targetSpaceId)
			focusWindow(win, function()
				addToWindowStack(win)
				centerMouseInWindow(win)
			end)
		end
		if onWindowReady then
			onWindowReady(win)
		end
	end

	-- Launch via menu if app is running, otherwise use launch command
	if app and app:isRunning() then
		app:activate()
		local didLaunch = app:selectMenuItem(menuPath)
		if didLaunch then
			waitForNewWindow(windowsBefore, bundleID, 20, handleNewWindow)
			return true
		end
	end

	if launchCommand then
		hs.execute(launchCommand, false)
		waitForNewWindow(windowsBefore, bundleID, 40, handleNewWindow)
		return true
	end

	return false
end

------------------------------------------
-- App Launching
------------------------------------------

function Actions.launchOrFocusApp(appName, launchCommand, opts)
	local singleton = opts and opts.singleton or false
	local launchViaMenu = opts and opts.launchViaMenu or false
	local focusIfExists = opts and opts.focusIfExists or false

	local app = hs.application.get(appName)
	if app and focusIfExists then
		-- Get app windows from CGWindowList (fast) instead of app:allWindows()
		local cgData = Windows.getWindowsFromCGWindowList()
		local appWindowIds = cgData.byApp[app:name()] or {}
		local appWindowsById = {}
		for _, winId in ipairs(appWindowIds) do
			appWindowsById[winId] = getWindow(winId)
		end

		local candidateWindowIds = {}
		if singleton then
			for screenId, spaces in pairs(state.screens) do
				for spaceId, space in pairs(spaces) do
					for colIdx, col in ipairs(space.cols) do
						for rowIdx, winId in ipairs(col) do
							if appWindowsById[winId] then
								table.insert(candidateWindowIds, winId)
							end
						end
					end
				end
			end
		else
			for screenId, spaces in pairs(state.screens) do
				for spaceId, space in pairs(spaces) do
					if spaceId == state.activeSpaceForScreen[screenId] then
						for colIdx, col in ipairs(space.cols) do
							for rowIdx, winId in ipairs(col) do
								if appWindowsById[winId] then
									table.insert(candidateWindowIds, winId)
								end
							end
						end
					end
				end
			end
		end

		local nextWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
		local nextWindowId = candidateWindowIds[nextWindowIdx] or candidateWindowIds[1]
		if nextWindowId then
			local screenId, spaceId, _, _ = locateWindow(nextWindowId)
			if not screenId or not spaceId then
				return
			end
			local currentSpaceId = state.activeSpaceForScreen[screenId]
			if spaceId ~= currentSpaceId then
				state.activeSpaceForScreen[screenId] = spaceId
				moveSpaceWindowsOffscreen(screenId, currentSpaceId)
				retile(screenId, spaceId)
				updateMenubar()
			end
			local nextWindow = getWindow(nextWindowId)
			focusWindow(nextWindow, function()
				addToWindowStack(nextWindow)
				centerWindowInView(nextWindow)
				centerMouseInWindow(nextWindow)
			end)
			return
		end
	end

	local targetScreen = hs.mouse.getCurrentScreen()
	local targetScreenId = targetScreen:id()
	local targetSpaceId = state.activeSpaceForScreen[targetScreenId]

	local candidateWindowIds = flatten(state.screens[targetScreenId][targetSpaceId].cols)
	local earliestWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
	if earliestWindowIdx == nil then
		earliestWindowIdx = 1
	end
	local targetColIdx
	if #candidateWindowIds > 0 then
		_, _, targetColIdx, _ = locateWindow(candidateWindowIds[earliestWindowIdx])
		if targetColIdx ~= nil then
			targetColIdx = targetColIdx + 1
		end
		if targetColIdx == nil then
			targetColIdx = 1
		end
	else
		targetColIdx = 1
	end

	-- Track windows before launch using CGWindowList (fast)
	local windowsBefore = {}
	local cgDataBefore = Windows.getWindowsFromCGWindowList()
	for winId, _ in pairs(cgDataBefore.byId) do
		windowsBefore[winId] = true
	end

	local function waitForNewWindow(attempts, callback)
		if attempts <= 0 then
			return
		end
		-- Check for new windows using CGWindowList (fast)
		local cgDataAfter = Windows.getWindowsFromCGWindowList()
		for winId, _ in pairs(cgDataAfter.byId) do
			if not windowsBefore[winId] then
				local win = getWindow(winId)
				if win then
					callback(win)
					return
				end
			end
		end
		hs.timer.doAfter(0.025, function()
			waitForNewWindow(attempts - 1, callback)
		end)
	end

	local function waitAndHandleNewWindow()
		waitForNewWindow(10, function(newWindow)
			table.insert(state.screens[targetScreenId][targetSpaceId].cols, targetColIdx, { newWindow:id() })
			retile(targetScreenId, targetSpaceId)
			focusWindow(newWindow, function()
				addToWindowStack(newWindow)
				centerWindowInView(newWindow)
				centerMouseInWindow(newWindow)
			end)
		end)
	end

	if launchViaMenu then
		if app and app:isRunning() then
			app:activate()
			local didLaunch = app:selectMenuItem({ "File", "New Window" })
			if didLaunch then
				waitAndHandleNewWindow()
				return
			end
		end
	end

	hs.execute(launchCommand, false)
	waitAndHandleNewWindow()
end

------------------------------------------
-- Scrolling & Panning
------------------------------------------

-- Pan the viewport horizontally by delta pixels (positive = right, negative = left)
-- Clamps to prevent panning past first/last window
function Actions.panViewport(delta)
	local screen = hs.mouse.getCurrentScreen()
	if not screen then
		return
	end
	local screenId = screen:id()
	local spaceId = state.activeSpaceForScreen[screenId]
	if not spaceId then
		return
	end

	local cols = state.screens[screenId][spaceId].cols
	if not cols or #cols == 0 then
		return
	end

	-- Calculate total width of all windows
	local totalWidth = 0
	for _, col in ipairs(cols) do
		local maxColWidth = 0
		for _, winId in ipairs(col) do
			local win = getWindow(winId)
			if win then
				local w = win:frame().w
				if w > maxColWidth then
					maxColWidth = w
				end
			end
		end
		totalWidth = totalWidth + maxColWidth + tileGap
	end
	totalWidth = totalWidth - tileGap -- no gap after last column

	local screenFrame = screen:frame()
	local currentStartX = state.startXForScreenAndSpace[screenId][spaceId] or 0
	local newStartX = currentStartX + delta

	-- Clamp: don't pan past left edge of first window (startX <= 0)
	-- and don't pan past right edge of last window
	local minStartX = screenFrame.w - totalWidth
	local maxStartX = 0

	if minStartX > maxStartX then
		-- All windows fit on screen, center them
		minStartX = (screenFrame.w - totalWidth) / 2
		maxStartX = minStartX
	end

	newStartX = math.max(minStartX, math.min(maxStartX, newStartX))

	if newStartX ~= currentStartX then
		state.startXForScreenAndSpace[screenId][spaceId] = newStartX
		retile(screenId, spaceId, { duration = 0 })
	end
end

function Actions.scroll(direction, opts)
	local ignoreApps = opts.ignoreApps or {}
	local win = hs.window.focusedWindow()
	local appName = win and win:application():name() or ""
	local ignore = false
	for _, n in ipairs(ignoreApps) do
		if appName == n then
			ignore = true
			break
		end
	end

	if not ignore then
		centerMouseInWindow(win)
		local delta = (direction == "up" and scrollSpeed) or -scrollSpeed
		hs.eventtap.event.newScrollEvent({ 0, delta }, {}, "pixel"):post()
	else
		local key = (direction == "up" and "u") or "d"
		hs.eventtap.keyStroke({ "ctrl" }, key, 0, win:application())
	end
end

------------------------------------------
-- Tab Navigation
------------------------------------------

-- Get current tab index using axuielement
local function getCurrentTabIndex(win)
	local ax = hs.axuielement.windowElement(win)
	if not ax then
		return 1
	end

	-- Find tab group recursively
	local function findTabGroup(element, depth)
		depth = depth or 0
		if depth > 5 then return nil end

		local role = element:attributeValue("AXRole")
		if role == "AXTabGroup" then
			return element
		end

		local children = element:attributeValue("AXChildren")
		if children then
			for _, child in ipairs(children) do
				local result = findTabGroup(child, depth + 1)
				if result then return result end
			end
		end
		return nil
	end

	local tabGroup = findTabGroup(ax)
	if not tabGroup then
		return 1
	end

	local tabs = tabGroup:attributeValue("AXTabs")
	if not tabs then
		return 1
	end

	-- Find the selected tab (AXValue = true)
	for i, tab in ipairs(tabs) do
		local selected = tab:attributeValue("AXValue")
		if selected == true or selected == 1 then
			return i
		end
	end

	return 1
end

-- Switch to next/previous tab and update window manager state
function Actions.switchTab(direction)
	local win = hs.window.focusedWindow()
	if not win then
		return
	end

	local tabCount = win:tabCount()

	-- If no tabs, pass the keystroke through to the application
	if not tabCount or tabCount <= 1 then
		local app = win:application()
		if direction == "next" then
			hs.eventtap.keyStroke({"cmd", "shift"}, "]", 0, app)
		else
			hs.eventtap.keyStroke({"cmd", "shift"}, "[", 0, app)
		end
		return
	end

	-- Get current state before switching
	local oldWinId = win:id()
	local screenId, spaceId, colIdx, rowIdx = locateWindow(oldWinId)
	local appName = win:application():name()

	-- Get current tab index
	local currentTabIdx = getCurrentTabIndex(win)

	-- Calculate new tab index
	local newTabIdx
	if direction == "next" then
		newTabIdx = currentTabIdx + 1
		if newTabIdx > tabCount then
			newTabIdx = 1 -- Wrap around
		end
	else
		newTabIdx = currentTabIdx - 1
		if newTabIdx < 1 then
			newTabIdx = tabCount -- Wrap around
		end
	end

	-- Switch tab
	print(string.format("[switchTab] %s: tab %d -> %d (of %d)", appName, currentTabIdx, newTabIdx, tabCount))
	win:focusTab(newTabIdx)

	-- Give macOS a moment to update the window
	hs.timer.doAfter(0.05, function()
		local newWin = hs.window.focusedWindow()
		if not newWin then
			return
		end

		local newWinId = newWin:id()

		-- If window ID changed and we had it in state, update state
		if newWinId ~= oldWinId and screenId and colIdx then
			print(string.format("[switchTab] Replacing window %d with %d in col %d", oldWinId, newWinId, colIdx))

			-- Replace old window ID with new one in the state
			local col = state.screens[screenId][spaceId].cols[colIdx]
			if col then
				for i, wid in ipairs(col) do
					if wid == oldWinId then
						col[i] = newWinId
						break
					end
				end
			end

			-- Update window stack
			for i, wid in ipairs(state.windowStack) do
				if wid == oldWinId then
					state.windowStack[i] = newWinId
					break
				end
			end

			-- Update fullscreen original width if present
			if state.fullscreenOriginalWidth[oldWinId] then
				state.fullscreenOriginalWidth[newWinId] = state.fullscreenOriginalWidth[oldWinId]
				state.fullscreenOriginalWidth[oldWinId] = nil
			end

			-- Update urgent windows if present
			if state.urgentWindows[oldWinId] then
				state.urgentWindows[newWinId] = state.urgentWindows[oldWinId]
				state.urgentWindows[oldWinId] = nil
			end
		elseif newWinId ~= oldWinId and not screenId then
			-- Old window wasn't in state, add new one
			print(string.format("[switchTab] Adding new window %d to state", newWinId))
			addToWindowStack(newWin)
		end
	end)
end

------------------------------------------
-- Initialization
------------------------------------------

function Actions.init(wm)
	WM = wm
	state = WM.State.get()
	Windows = WM.Windows
	Tiling = WM.Tiling
	Spaces = WM.Spaces
	Urgency = WM.Urgency
	Events = WM.Events

	-- Cache function references
	getWindow = Windows.getWindow
	addToWindowStack = Windows.addToWindowStack
	debouncedAddToWindowStack = Windows.debouncedAddToWindowStack
	cleanWindowStack = Windows.cleanWindowStack
	locateWindow = Windows.locateWindow
	focusWindow = Windows.focusWindow
	centerMouseInWindow = Windows.centerMouseInWindow
	flatten = Windows.flatten
	earliestIndexInList = Windows.earliestIndexInList
	retile = Tiling.retile
	retileAll = Tiling.retileAll
	bringIntoView = Tiling.bringIntoView
	moveSpaceWindowsOffscreen = Tiling.moveSpaceWindowsOffscreen
	getUrgentWindowsInSpace = Spaces.getUrgentWindowsInSpace
	updateMenubar = WM.UI.updateMenubar

	-- Cache constants
	tileGap = WM.tileGap
	resizeStep = WM.resizeStep
	scrollSpeed = WM.scrollSpeed

	print("[Actions] Module initialized")
end

return Actions
