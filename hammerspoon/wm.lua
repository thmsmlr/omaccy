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

local _windows = {}
local state = {
	screens = {},
	activeSpaceForScreen = {},
	windowStack = {},
	windowStackIndex = 1,
	startXForScreenAndSpace = {},
	fullscreenOriginalWidth = {},
}

-- Command palette state (not persisted)
local commandPaletteMode = "root" -- "root" or "moveWindowToSpace"

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

- retile(state, screenId, spaceId, startX) -> tiles the windows on the given screen and space

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

local addToWindowStack

local function flatten(tbl)
	local result = {}
	for _, sublist in ipairs(tbl) do
		for _, v in ipairs(sublist) do
			table.insert(result, v)
		end
	end
	return result
end

local function getWindow(winId)
	if _windows[winId] then
		return _windows[winId]
	end
	_windows[winId] = Window(winId)
	return _windows[winId]
end

-- Removes invalid or closed windows from the window stack
local function cleanWindowStack()
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

local function focusWindow(w, callback)
	local function waitForFocus(attempts)
		if attempts == 0 then
			return
		end
		local app = w:application()
		app:activate(true)
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
			if callback then
				callback()
			end
		end
	end

	waitForFocus(10)
end

local function locateWindow(windowId)
	local currentWindow = getWindow(windowId)
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

local function updateZOrder(cols, focusedWindowId)
	if not cols or #cols == 0 or not focusedWindowId then
		return
	end

	local totalWindowCount = #flatten(cols)
	local screenId, _, focusedColIdx = locateWindow(focusedWindowId)
	if not focusedColIdx or not screenId then
		return
	end
	local screenFrame = Screen(screenId):frame()

	-- Build desired front-to-back order
	local ordered = {}

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

	table.insert(ordered, focusedWindowId) -- 1) focused window
	appendColumn(focusedColIdx, focusedWindowId) -- 2) rest of its column

	local offset = 1 -- 3) neighbouring columns
	while #ordered < totalWindowCount do
		local leftIdx = focusedColIdx - offset
		local rightIdx = focusedColIdx + offset

		-- For the immediate neighbours we may need to swap priority based on
		-- whether either neighbour is clamped against the screen edge.
		if offset == 1 then
			local function isClamped(idx, side)
				if idx < 1 or idx > #cols then
					return false
				end
				local firstWinId = cols[idx][1]
				if not firstWinId then
					return false
				end
				local f = getWindow(firstWinId):frame()
				if side == "left" then
					return f.x <= screenFrame.x + 1
				end
				if side == "right" then
					return (f.x + f.w) >= (screenFrame.x + screenFrame.w - 1)
				end
				return false
			end

			local leftClamped = isClamped(leftIdx, "left")
			local rightClamped = isClamped(rightIdx, "right")

			-- Default ordering is left then right. If the left column is clamped
			-- we want the right column to appear in front, so we reverse the
			-- order.  When the right column is clamped, the default ordering is
			-- already correct, so no change is needed.
			if leftClamped and not rightClamped then
				if rightIdx <= #cols then
					appendColumn(rightIdx)
				end
				if leftIdx >= 1 then
					appendColumn(leftIdx)
				end
			else
				if leftIdx >= 1 then
					appendColumn(leftIdx)
				end
				if rightIdx <= #cols then
					appendColumn(rightIdx)
				end
			end
		else
			if leftIdx >= 1 then
				appendColumn(leftIdx)
			end
			if rightIdx <= #cols then
				appendColumn(rightIdx)
			end
		end
		offset = offset + 1
	end

	-- Current positions in the global z-stack (front = small index)
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

	-- Raise back→front, but only if relative order is wrong
	local minFront = math.huge
	for i = #ordered, 1, -1 do
		local id = ordered[i]
		local pos = currentPos[id] or math.huge

		if pos > minFront then -- behind something it should front-run
			local w = getWindow(id)
			if w then
				w:raise()
			end
			minFront = 0
		else
			if pos < minFront then
				minFront = pos
			end
		end
	end
end

local function framesDiffer(f1, f2, tolerance)
	tolerance = tolerance or 1
	return math.abs(f1.x - f2.x) > tolerance
		or math.abs(f1.y - f2.y) > tolerance
		or math.abs(f1.w - f2.w) > tolerance
		or math.abs(f1.h - f2.h) > tolerance
end

local function retile(state, screenId, spaceId, opts)
	opts = opts or {}

	local focusedWindow = Window.focusedWindow()
	local focusedWindowId = focusedWindow and focusedWindow:id() or nil
	local cols = state.screens[screenId][spaceId].cols
	local screen = Screen(screenId)
	if not cols or #cols == 0 then
		return
	end

	local screenFrame = screen:frame()
	local y = screenFrame.y
	local h = screenFrame.h
	local x = screenFrame.x + state.startXForScreenAndSpace[screenId][spaceId]

	local targetColIdx = nil

	-- Phase 1: Calculate all target frames and categorize windows
	local visibleUpdates = {}
	local offscreenUpdates = {}

	local currentX = x
	for idx, col in ipairs(cols) do
		-- Find the maximum width in this column
		local maxColWidth = 0
		for _, winId in ipairs(col) do
			local win = getWindow(winId)
			if win then
				local frame = win:frame()
				if frame.w > maxColWidth then
					maxColWidth = frame.w
				end
			end
		end

		-- Calculate the height each window should have to fill the column
		local n = #col
		local totalGap = WM.tileGap * (n - 1)
		local availableHeight = screenFrame.h - totalGap
		local baseHeight = math.floor(availableHeight / n)
		local remainder = availableHeight - (baseHeight * n) -- Distribute remainder pixels

		local colX = currentX
		local rowY = y
		for jdx, winId in ipairs(col) do
			local win = getWindow(winId)
			if win then
				local currentFrame = win:frame()
				local targetFrame = {
					x = math.min(
						math.max(colX, screenFrame.x - (maxColWidth / 2) + 1),
						screenFrame.x + screenFrame.w - (maxColWidth / 2) - 1
					),
					y = rowY,
					w = maxColWidth,
					h = baseHeight + ((jdx <= remainder) and 1 or 0),
				}

				-- Determine if window will be visible on screen
				-- Only consider "visible" if mostly on screen (not just edge-clipped)
				local winLeft = targetFrame.x
				local winRight = targetFrame.x + targetFrame.w
				local screenLeft = screenFrame.x
				local screenRight = screenFrame.x + screenFrame.w

				-- Calculate what percentage of the window is actually on screen
				local visibleLeft = math.max(winLeft, screenLeft)
				local visibleRight = math.min(winRight, screenRight)
				local visibleWidth = math.max(0, visibleRight - visibleLeft)
				local percentVisible = visibleWidth / targetFrame.w

				-- Only consider "visible" if at least 52% is on screen
				local isVisible = percentVisible > 0.52

				local update = {
					winId = winId,
					win = win,
					currentFrame = currentFrame,
					targetFrame = targetFrame,
					isVisible = isVisible,
					colIdx = idx,
				}

				if isVisible then
					table.insert(visibleUpdates, update)
				else
					table.insert(offscreenUpdates, update)
				end

				rowY = rowY + targetFrame.h + WM.tileGap
				if winId == focusedWindowId then
					targetColIdx = idx
				end
			end
		end
		currentX = currentX + maxColWidth + WM.tileGap
	end

	-- Phase 2: Process visible windows first (user sees these immediately)
	if not opts.onlyOffscreen then
		for _, update in ipairs(visibleUpdates) do
			if framesDiffer(update.currentFrame, update.targetFrame) then
				if opts.duration then
					update.win:setFrame(update.targetFrame, opts.duration)
				else
					update.win:setFrame(update.targetFrame)
				end
			end
		end
	end

	-- Phase 3: Process offscreen windows (user doesn't see these)
	if not opts.onlyVisible then
		for _, update in ipairs(offscreenUpdates) do
			if framesDiffer(update.currentFrame, update.targetFrame) then
				if opts.duration then
					update.win:setFrame(update.targetFrame, opts.duration)
				else
					update.win:setFrame(update.targetFrame)
				end
			end
		end
	end
end

local function bringIntoView(win)
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	local screenFrame = Screen(screenId):frame()

	-- Total width (plus gaps) before the target window in the stack
	local preWidth = 0
	for i = 1, colIdx - 1 do
		local winId = state.screens[screenId][spaceId].cols[i][1]
		local win = getWindow(winId)
		preWidth = preWidth + win:frame().w + WM.tileGap
	end

	-- Current on-screen position of the target window
	local currentLeft = win:frame().x
	local currentRight = win:frame().x + win:frame().w

	local newStartX
	if currentLeft < 0 then
		newStartX = -preWidth
	elseif currentRight > screenFrame.w then
		newStartX = -preWidth + screenFrame.w - win:frame().w
	else
		newStartX = -preWidth + currentLeft
	end

	-- Only retile if startX actually changed
	local oldStartX = state.startXForScreenAndSpace[screenId][spaceId]
	state.startXForScreenAndSpace[screenId][spaceId] = newStartX
	if math.abs(newStartX - oldStartX) > 1 then
		retile(state, screenId, spaceId)
	end
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

local function centerMouseInWindow(win)
	if not win then
		return
	end
	local f = win:frame()
	Mouse.absolutePosition({ x = f.x + f.w / 2, y = f.y + f.h / 2 })
end

local function getRightmostScreen()
	local rightmostScreen = Screen.mainScreen()
	local maxRight = -math.huge
	for _, screen in ipairs(Screen.allScreens()) do
		local frame = screen:frame()
		local right = frame.x + frame.w
		if right > maxRight then
			maxRight = right
			rightmostScreen = screen
		end
	end
	return rightmostScreen
end

-- Move all windows of the given space on the given screen to the rightmost edge of the rightmost screen
local function moveSpaceWindowsOffscreen(screenId, spaceId, opts)
	opts = opts or {}
	if not state.screens[screenId] or not state.screens[screenId][spaceId] then
		return
	end

	local rightmostScreen = getRightmostScreen()
	local rightFrame = rightmostScreen:frame()
	local offscreenX = rightFrame.x + rightFrame.w - 1 -- leave 1px visible so macOS doesn't move it
	local screenFrame = Screen(screenId):frame()
	local screenLeft = screenFrame.x
	local screenRight = screenFrame.x + screenFrame.w

	local function processWindow(winId)
		local win = getWindow(winId)
		if win and win:isStandard() and win:isVisible() then
			local f = win:frame()

			-- Check if window is currently visible on screen
			-- Only consider "visible" if at least 75% is on screen
			local winLeft = f.x
			local winRight = f.x + f.w
			local visibleLeft = math.max(winLeft, screenLeft)
			local visibleRight = math.min(winRight, screenRight)
			local visibleWidth = math.max(0, visibleRight - visibleLeft)
			local percentVisible = visibleWidth / f.w
			local isCurrentlyVisible = percentVisible > 0.75

			-- Skip based on priority mode
			if opts.onlyVisible and not isCurrentlyVisible then
				return
			end
			if opts.onlyOffscreen and isCurrentlyVisible then
				return
			end

			-- Only move if not already offscreen
			if math.abs(f.x - offscreenX) > 1 then
				f.x = offscreenX
				win:setFrame(f, 0)
			end
		end
	end

	-- Move tiled windows
	for _, col in ipairs(state.screens[screenId][spaceId].cols) do
		for _, winId in ipairs(col) do
			processWindow(winId)
		end
	end

	-- Move floating windows if any
	if state.screens[screenId][spaceId].floating then
		for _, winId in ipairs(state.screens[screenId][spaceId].floating) do
			processWindow(winId)
		end
	end
end

local function retileAll(opts)
	for screenId, spaces in pairs(state.screens) do
		for spaceId, _ in pairs(spaces) do
			if state.activeSpaceForScreen[screenId] == spaceId then
				retile(state, screenId, spaceId, opts)
			else
				moveSpaceWindowsOffscreen(screenId, spaceId)
			end
		end
	end
end

-- Helper: Build space list for switching or moving
local function buildSpaceList(query, actionType)
	local choices = {}
	query = query or ""

	-- Get all screens sorted by x position (left to right)
	local screens = Screen.allScreens()
	table.sort(screens, function(a, b)
		return a:frame().x < b:frame().x
	end)

	-- Check if query matches an existing space (that has windows)
	local queryMatchesExisting = false
	if query ~= "" then
		-- Check if query is a numbered space
		local queryNum = tonumber(query)
		if queryNum then
			-- Check if this numbered space exists on any screen and has windows
			for _, screen in ipairs(screens) do
				local screenId = screen:id()
				if state.screens[screenId] and state.screens[screenId][queryNum] then
					local space = state.screens[screenId][queryNum]
					local hasWindows = (space.cols and #space.cols > 0) or (space.floating and #space.floating > 0)
					if hasWindows then
						queryMatchesExisting = true
						break
					end
				end
			end
		else
			-- Check if query matches any named space
			for _, screen in ipairs(screens) do
				local screenId = screen:id()
				if state.screens[screenId] and state.screens[screenId][query] then
					queryMatchesExisting = true
					break
				end
			end
		end
	end

	-- Add "Create space" option if query doesn't match and isn't empty (only for switchSpace action)
	if actionType == "switchSpace" and query ~= "" and not queryMatchesExisting then
		local currentScreen = Mouse.getCurrentScreen()
		table.insert(choices, {
			text = "+ Create space: " .. query,
			subText = "Create new named space and switch to it",
			screenId = currentScreen:id(),
			spaceId = query,
			actionType = "createAndSwitchSpace",
		})
	end

	-- Build choices for each screen's spaces
	for screenIdx, screen in ipairs(screens) do
		local screenId = screen:id()
		local activeSpaceId = state.activeSpaceForScreen[screenId]

		-- Iterate all spaces on this screen (both numbered and named)
		if state.screens[screenId] then
			for spaceId, space in pairs(state.screens[screenId]) do
				-- Count windows in this space
				local windowCount = 0
				if space.cols then
					for _, col in ipairs(space.cols) do
						windowCount = windowCount + #col
					end
				end
				if space.floating then
					windowCount = windowCount + #space.floating
				end

				-- Only show spaces that have windows
				if windowCount == 0 then
					goto continue
				end

				-- Build display text
				local text
				local subText
				local isCurrent = (spaceId == activeSpaceId)
				local hasMultipleScreens = #screens > 1

				if type(spaceId) == "string" then
					text = spaceId -- Named space: show the name
					-- Build subtext: only show screen if multiple screens, and current marker
					local parts = {}
					if hasMultipleScreens then
						table.insert(parts, "Screen " .. screenIdx)
					end
					if isCurrent then
						table.insert(parts, "(current)")
					end
					subText = table.concat(parts, " · ")
				else
					text = tostring(spaceId) -- Just the number: "1", "2", "3", "4"
					-- Build subtext: "Space N" + optional screen + optional current marker
					local parts = { "Space " .. spaceId }
					if hasMultipleScreens then
						table.insert(parts, "Screen " .. screenIdx)
					end
					if isCurrent then
						table.insert(parts, "(current)")
					end
					subText = table.concat(parts, " · ")
				end

				table.insert(choices, {
					text = text,
					subText = subText,
					screenId = screenId,
					spaceId = spaceId,
					isCurrent = isCurrent,
					actionType = actionType,
				})

				::continue::
			end
		end
	end

	-- Filter choices based on query (simple fuzzy matching)
	if query ~= "" then
		local filtered = {}
		local lowerQuery = string.lower(query)

		for _, choice in ipairs(choices) do
			-- Always include the create action
			if choice.actionType == "createAndSwitchSpace" then
				table.insert(filtered, choice)
			else
				-- Simple fuzzy match: check if query matches text or subtext
				local text = string.lower(choice.text)
				local subText = choice.subText and string.lower(choice.subText) or ""

				if text:find(lowerQuery, 1, true) or subText:find(lowerQuery, 1, true) then
					table.insert(filtered, choice)
				end
			end
		end
		choices = filtered
	end

	-- Sort: current space first, then by screen, then by spaceId
	table.sort(choices, function(a, b)
		-- Create action always comes first
		if (a.actionType == "createAndSwitchSpace") ~= (b.actionType == "createAndSwitchSpace") then
			return a.actionType == "createAndSwitchSpace"
		end
		if a.isCurrent ~= b.isCurrent then
			return a.isCurrent -- current space first
		end
		if a.screenId ~= b.screenId then
			return a.screenId < b.screenId
		end
		-- Sort spaceIds: numbers before strings, then alphabetically
		local aIsNum = type(a.spaceId) == "number"
		local bIsNum = type(b.spaceId) == "number"
		if aIsNum ~= bIsNum then
			return aIsNum -- numbers before strings
		end
		return tostring(a.spaceId) < tostring(b.spaceId)
	end)

	return choices
end

local function buildCommandPaletteChoices(query)
	query = query or ""

	if commandPaletteMode == "root" then
		-- Root menu: show spaces directly for switching, plus "Move window to space" command
		local choices = buildSpaceList(query, "switchSpace")

		-- Add "Move window to space" command at the bottom (less common action)
		table.insert(choices, {
			text = "Move window to space",
			subText = "Move focused window to another space",
			actionType = "navigateToMoveWindow",
			valid = false, -- Don't close chooser when selected
		})

		return choices
	elseif commandPaletteMode == "moveWindowToSpace" then
		-- Show space list with "move window to space" action
		local choices = buildSpaceList(query, "moveWindowToSpace")

		return choices
	end

	return {}
end

local function updateMenubar()
	if not WM._menubar then
		return
	end

	-- Get all screens sorted by x position (left to right)
	local screens = Screen.allScreens()
	table.sort(screens, function(a, b)
		return a:frame().x < b:frame().x
	end)

	-- Build title showing each screen's active space (e.g., "1|2")
	local titleParts = {}
	for _, screen in ipairs(screens) do
		local screenId = screen:id()
		local spaceId = state.activeSpaceForScreen[screenId] or 1
		-- For named spaces, show abbreviated name or first 3 chars
		local displayText
		if type(spaceId) == "string" then
			displayText = string.sub(spaceId, 1, 3)
		else
			displayText = tostring(spaceId)
		end
		table.insert(titleParts, displayText)
	end
	local title = table.concat(titleParts, "|")

	-- Create menu for switching spaces on the current screen
	local currentScreen = Mouse.getCurrentScreen()
	local currentScreenId = currentScreen:id()
	local currentSpaceId = state.activeSpaceForScreen[currentScreenId] or 1

	local menu = {}
	for i = 1, 4 do
		local checked = (i == currentSpaceId)
		table.insert(menu, {
			title = "Space " .. i,
			checked = checked,
			fn = function()
				WM:switchToSpace(i)
			end,
		})
	end

	WM._menubar:setTitle(title)
	WM._menubar:setMenu(menu)
end

function WM:showCommandPalette()
	if not WM._commandPalette then
		return
	end

	-- Reset to root mode
	commandPaletteMode = "root"

	-- Refresh choices when showing
	local choices = buildCommandPaletteChoices()
	WM._commandPalette:choices(choices)
	WM._commandPalette:query("") -- Clear search text from previous invocation
	WM._commandPalette:show()
end

local function getWindowStackIndex(winId)
	for i, v in ipairs(state.windowStack) do
		if v == winId then
			return i
		end
	end
end

addToWindowStack = function(win)
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
	local idx = getWindowStackIndex(id)
	if idx then
		table.remove(state.windowStack, idx)
	end
	table.insert(state.windowStack, 1, id)
	if #state.windowStack > 50 then
		table.remove(state.windowStack)
	end

	-- print("--- Add to window stack ---")
	-- for i, id in ipairs(state.windowStack) do
	--     local w = getWindow(id)
	--     local title = w and w:title() or tostring(id)
	--     local marker = (i == state.windowStackIndex) and ">" or " "
	--     print(string.format("%s [%d] %s", marker, i, title))
	-- end
end

local windowWatcherPaused = false
WM._windowWatcher = hs.window.filter.new()
WM._menubar = nil

WM._windowWatcher:subscribe(hs.window.filter.windowFocused, function(win, appName, event)
	if windowWatcherPaused then
		return
	end
	print("[windowFocused]", win:title(), win:id(), windowWatcherPaused)
	addToWindowStack(win)
	local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
	if not screenId or not spaceId or not colIdx or not rowIdx then
		return
	end
	if state.activeSpaceForScreen[screenId] ~= spaceId then
		local oldSpaceId = state.activeSpaceForScreen[screenId]
		state.activeSpaceForScreen[screenId] = spaceId
		-- Only retile the affected screen's spaces
		moveSpaceWindowsOffscreen(screenId, oldSpaceId)
		retile(state, screenId, spaceId)

		-- Update menubar to reflect space change
		updateMenubar()
	end
	bringIntoView(win)
end)

-- Subscribe to window created/destroyed events to update state

WM._windowWatcher:subscribe(hs.window.filter.windowCreated, function(win, appName, event)
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
	local screenId = screen and screen:id() or Screen.mainScreen():id()
	local spaceId = state.activeSpaceForScreen[screenId] or 1

	-- Place in a new column at the end
	local cols = state.screens[screenId][spaceId].cols
	local colIdx = #cols + 1
	cols[colIdx] = cols[colIdx] or {}
	table.insert(cols[colIdx], win:id())

	addToWindowStack(win)
	cleanWindowStack()
	-- retile(state, screenId, spaceId)
	retileAll()
end)

WM._windowWatcher:subscribe(hs.window.filter.windowDestroyed, function(win, appName, event)
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

WM._windowWatcher:subscribe(
	{ hs.window.filter.windowFullscreened, hs.window.filter.windowUnfullscreened },
	function(win, appName, event)
		if windowWatcherPaused then
			return
		end
		retileAll()
	end
)

function WM:navigateStack(direction)
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
		return
	end
	local win = getWindow(winId)
	if not win then
		return
	end

	-- print("--- Navigate window stack ---")
	-- for i, id in ipairs(state.windowStack) do
	--     local w = getWindow(id)
	--     local title = w and w:title() or tostring(id)
	--     local marker = (i == state.windowStackIndex) and ">" or " "
	--     print(string.format("%s [%d] %s", marker, i, title))
	-- end

	local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
	if not screenId or not spaceId then
		return
	end
	local currentSpaceId = state.activeSpaceForScreen[screenId]
	local switchingSpaces = (spaceId ~= currentSpaceId)

	if switchingSpaces then
		-- Calculate correct startX BEFORE switching spaces
		local screenFrame = Screen(screenId):frame()

		-- Calculate total width before the target window in the stack
		local preWidth = 0
		for i = 1, colIdx - 1 do
			local preWinId = state.screens[screenId][spaceId].cols[i][1]
			local w = getWindow(preWinId)
			if w then
				preWidth = preWidth + w:frame().w + WM.tileGap
			end
		end

		-- Center the target window on screen
		local targetX = (screenFrame.w - win:frame().w) / 2
		local newStartX = targetX - preWidth
		state.startXForScreenAndSpace[screenId][spaceId] = newStartX

		-- Switch spaces with zero animation to avoid windows flying across screen
		state.activeSpaceForScreen[screenId] = spaceId
		moveSpaceWindowsOffscreen(screenId, currentSpaceId)
		retile(state, screenId, spaceId, { duration = 0 })

		-- Update menubar to reflect space change
		updateMenubar()
	end

	windowWatcherPaused = true
	focusWindow(win, function()
		-- Only bringIntoView if we're not switching spaces (already positioned correctly)
		if not switchingSpaces then
			bringIntoView(win)
		end
		centerMouseInWindow(win)
		hs.timer.doAfter(0.1, function()
			windowWatcherPaused = false
		end)
	end)
end

function WM:focusDirection(direction)
	windowWatcherPaused = true
	local focusedWindow = Window.focusedWindow()
	if not focusedWindow then
		return
	end
	local currentScreenId, currentSpace, currentColIdx, currentRowIdx = locateWindow(focusedWindow:id())

	if not currentColIdx then
		return
	end
	if direction == "left" then
		currentColIdx = currentColIdx - 1
		if currentColIdx < 1 then
			return
		end
		currentRowIdx = earliestIndexInList(
			state.screens[currentScreenId][currentSpace].cols[currentColIdx],
			state.windowStack
		) or 1
	end
	if direction == "right" then
		currentColIdx = currentColIdx + 1
		if currentColIdx > #state.screens[currentScreenId][currentSpace].cols then
			return
		end
		currentRowIdx = earliestIndexInList(
			state.screens[currentScreenId][currentSpace].cols[currentColIdx],
			state.windowStack
		) or 1
	end

	if direction == "down" then
		currentRowIdx = currentRowIdx + 1
	end
	if direction == "up" then
		currentRowIdx = currentRowIdx - 1
	end
	if currentRowIdx < 1 then
		return
	end
	if currentRowIdx > #state.screens[currentScreenId][currentSpace].cols[currentColIdx] then
		return
	end

	local nextWindow = getWindow(state.screens[currentScreenId][currentSpace].cols[currentColIdx][currentRowIdx])
	if nextWindow then
		focusWindow(nextWindow, function()
			addToWindowStack(nextWindow)
			bringIntoView(nextWindow)
			centerMouseInWindow(nextWindow)
			hs.timer.doAfter(0.1, function()
				windowWatcherPaused = false
			end)
		end)
	end
end

function WM:moveDirection(direction)
	local focusedWindow = Window.focusedWindow()
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

function WM:nextScreen()
	local currentScreen = Mouse.getCurrentScreen()
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
		local screenFrame = Screen(nextScreenId):frame()
		local centerX = screenFrame.x + screenFrame.w / 2
		local centerY = screenFrame.y + screenFrame.h / 2
		Mouse.absolutePosition({ x = centerX, y = centerY })
	end
end

function WM:moveWindowToNextScreen()
	local currentWindow = Window.focusedWindow()
	if not currentWindow then
		return
	end
	local currentWindowId = currentWindow:id()
	local currentScreenId, currentSpace, currentColIdx, currentRowIdx = locateWindow(currentWindowId)
	local nextScreenId = currentWindow:screen():next():id()
	local nextSpace = state.activeSpaceForScreen[nextScreenId]

	table.insert(state.screens[nextScreenId][nextSpace].cols, { currentWindowId })
	table.remove(state.screens[currentScreenId][currentSpace].cols[currentColIdx], currentRowIdx)
	if #state.screens[currentScreenId][currentSpace].cols[currentColIdx] == 0 then
		table.remove(state.screens[currentScreenId][currentSpace].cols, currentColIdx)
	end

	retile(state, currentScreenId, currentSpace)
	retile(state, nextScreenId, nextSpace)
end

-- Toggle fullscreen horizontally for the focused window.
function WM:toggleFullscreen()
	local win = Window.focusedWindow()
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
end

function WM:centerWindow()
	local win = Window.focusedWindow()
	if not win then
		return
	end
	local screenId, spaceId, colIdx, _ = locateWindow(win:id())
	local screenFrame = Screen(screenId):frame()

	local preWidth = 0
	for i = 1, colIdx - 1 do
		preWidth = preWidth + getWindow(state.screens[screenId][spaceId].cols[i][1]):frame().w + WM.tileGap
	end

	local targetX = (screenFrame.w - win:frame().w) / 2
	local startX = targetX - preWidth
	state.startXForScreenAndSpace[screenId][spaceId] = startX
	retile(state, screenId, spaceId)
end

function WM:resizeFocusedWindowHorizontally(delta)
	local win = Window.focusedWindow()
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

	-- retile(state, screenId, spaceId)
	bringIntoView(win)
end

function WM:resizeFocusedWindowVertically(delta)
	local win = Window.focusedWindow()
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
	local screenFrame = Screen(screenId):frame()
	local minHeight = 50
	local totalColHeight = screenFrame.h - WM.tileGap * (n - 1)

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

	-- Distribute any leftover pixels (from rounding) to non-focused windows
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
		y = y + f.h + WM.tileGap
	end
end

function WM:switchToSpace(spaceId)
	windowWatcherPaused = true

	local currentScreen = Mouse.getCurrentScreen()
	local screenId = currentScreen:id()

	local currentSpace = state.activeSpaceForScreen[screenId]
	if currentSpace == spaceId then
		return
	end

	state.activeSpaceForScreen[screenId] = spaceId

	-- 4-phase optimized approach: show new content first, cleanup in background
	-- Since setFrame() doesn't change z-order, we can show new windows behind,
	-- raise them to top, then clean up old windows (user doesn't see this)

	-- Phase 1: Move ALL new space windows to their correct positions (not just visible)
	-- This ensures correctness - all windows are positioned before we raise any
	retile(state, screenId, spaceId, { duration = 0 })

	-- Phase 2: Raise visible windows to top (now they cover old windows)
	-- Use ONLY win:raise(), not app:activate(), to avoid raising ALL windows of that app
	local screenFrame = Screen(screenId):frame()
	local screenLeft = screenFrame.x
	local screenRight = screenFrame.x + screenFrame.w

	for _, col in ipairs(state.screens[screenId][spaceId].cols) do
		for _, winId in ipairs(col) do
			local win = getWindow(winId)
			if win then
				local f = win:frame()
				-- Only raise if >75% visible
				local winLeft = f.x
				local winRight = f.x + f.w
				local visibleLeft = math.max(winLeft, screenLeft)
				local visibleRight = math.min(winRight, screenRight)
				local visibleWidth = math.max(0, visibleRight - visibleLeft)
				local percentVisible = visibleWidth / f.w

				if percentVisible > 0.75 then
					win:raise() -- Just raise, don't activate app (avoids raising ALL windows)
				end
			end
		end
	end

	-- Phase 3: Clear old visible windows (user doesn't see this, already covered)
	moveSpaceWindowsOffscreen(screenId, currentSpace, { onlyVisible = true })

	-- Phase 4: Background cleanup - move ALL remaining old windows offscreen
	-- This prevents ghost windows from being raised later by focusWindow/app:activate
	moveSpaceWindowsOffscreen(screenId, currentSpace) -- No flags = move ALL windows

	-- Update menubar to reflect space change
	updateMenubar()

	local candidateWindowIds = flatten(state.screens[screenId][spaceId].cols)
	local nextWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
	local nextWindowId = candidateWindowIds[nextWindowIdx] or candidateWindowIds[1]
	if nextWindowId then
		local nextWindow = getWindow(nextWindowId)
		focusWindow(nextWindow, function()
			addToWindowStack(nextWindow)
			bringIntoView(nextWindow)
			centerMouseInWindow(nextWindow)
			hs.timer.doAfter(0.1, function()
				windowWatcherPaused = false
			end)
		end)
	else
		-- When switching to an empty space, delay re-enabling the watcher
		-- to prevent macOS from auto-focusing a window on another space and
		-- triggering an unwanted space switch back
		hs.timer.doAfter(0.2, function()
			windowWatcherPaused = false
		end)
	end
end

function WM:slurp()
	local win = Window.focusedWindow()
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

	-- Make all windows in the slurped column have the same height
	-- We'll set their heights to be equal, dividing the column height equally
	local screenFrame = Screen(screenId):frame()
	local col = cols[colIdx]
	local n = #col
	if n > 0 then
		local colHeight = screenFrame.h - WM.tileGap * (n - 1)
		local winHeight = math.floor(colHeight / n)
		local y = screenFrame.y
		for i = 1, n do
			local w = getWindow(col[i])
			if w then
				local f = w:frame()
				f.y = y
				f.h = winHeight
				w:setFrame(f)
				y = y + winHeight + WM.tileGap
			end
		end
	end

	retile(state, screenId, spaceId)
end

function WM:barf()
	local win = Window.focusedWindow()
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

	-- Make all windows in the affected columns have the same height
	local screenFrame = Screen(screenId):frame()
	for i = colIdx, colIdx + 1 do
		local col = cols[i]
		if col then
			local n = #col
			if n > 0 then
				local colHeight = screenFrame.h - WM.tileGap * (n - 1)
				local winHeight = math.floor(colHeight / n)
				local y = screenFrame.y
				for j = 1, n do
					local w = getWindow(col[j])
					if w then
						local f = w:frame()
						f.y = y
						f.h = winHeight
						w:setFrame(f)
						y = y + winHeight + WM.tileGap
					end
				end
			end
		end
	end

	retile(state, screenId, spaceId)
end

function WM:moveFocusedWindowToSpace(spaceId)
	local win = Window.focusedWindow()
	if not win then
		return
	end

	local screenId, currentSpace, colIdx, rowIdx = locateWindow(win:id())
	if not screenId or not currentSpace or not colIdx or not rowIdx then
		return
	end
	if currentSpace == spaceId then
		self:switchToSpace(spaceId)
		return
	end

	windowWatcherPaused = true

	local removedWin = table.remove(state.screens[screenId][currentSpace].cols[colIdx], rowIdx)
	if #state.screens[screenId][currentSpace].cols[colIdx] == 0 then
		table.remove(state.screens[screenId][currentSpace].cols, colIdx)
	end

	table.insert(state.screens[screenId][spaceId].cols, { removedWin })
	retile(state, screenId, currentSpace)
	self:switchToSpace(spaceId)

	windowWatcherPaused = false
end

function WM:closeFocusedWindow()
	local win = Window.focusedWindow()
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

function WM:createSpace(spaceId, screenId)
	-- Default to current screen if not specified
	screenId = screenId or Mouse.getCurrentScreen():id()

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

function WM:scroll(direction, opts)
	local ignoreApps = opts.ignoreApps or {}
	local win = Window.focusedWindow()
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
		local delta = (direction == "up" and WM.scrollSpeed) or -WM.scrollSpeed
		hs.eventtap.event.newScrollEvent({ 0, delta }, {}, "pixel"):post()
	else
		local key = (direction == "up" and "u") or "d"
		hs.eventtap.keyStroke({ "ctrl" }, key, 0, win:application())
	end
end

function WM:launchOrFocusApp(appName, launchCommand, opts)
	local singleton = opts and opts.singleton or false
	local launchViaMenu = opts and opts.launchViaMenu or false
	local focusIfExists = opts and opts.focusIfExists or false

	local app = Application.get(appName)
	if app and focusIfExists then
		local appWindowsById = {}
		for _, win in ipairs(app:allWindows()) do
			appWindowsById[win:id()] = win
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
			windowWatcherPaused = true
			local screenId, spaceId, _, _ = locateWindow(nextWindowId)
			if not screenId or not spaceId then
				return
			end
			local currentSpaceId = state.activeSpaceForScreen[screenId]
			if spaceId ~= currentSpaceId then
				state.activeSpaceForScreen[screenId] = spaceId
				-- Only retile the affected screen's spaces
				moveSpaceWindowsOffscreen(screenId, currentSpaceId)
				retile(state, screenId, spaceId)

				-- Update menubar to reflect space change
				updateMenubar()
			end
			local nextWindow = getWindow(nextWindowId)
			focusWindow(nextWindow, function()
				addToWindowStack(nextWindow)
				bringIntoView(nextWindow)
				centerMouseInWindow(nextWindow)
				hs.timer.doAfter(0.1, function()
					windowWatcherPaused = false
				end)
			end)
			return
		end
	end

	local targetScreen = Mouse.getCurrentScreen()
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

	local windowsBefore = {}
	for _, win in ipairs(Window.allWindows()) do
		windowsBefore[win:id()] = win
	end

	local function waitForNewWindow(attempts, callback)
		if attempts <= 0 then
			return
		end
		local windowsAfter = {}
		for _, win in ipairs(Window.allWindows()) do
			windowsAfter[win:id()] = win
		end
		for winId, win in pairs(windowsAfter) do
			if not windowsBefore[winId] then
				callback(win)
				return
			end
		end
		hs.timer.doAfter(0.025, function()
			waitForNewWindow(attempts - 1, callback)
		end)
	end

	local function waitAndHandleNewWindow()
		waitForNewWindow(10, function(newWindow)
			table.insert(state.screens[targetScreenId][targetSpaceId].cols, targetColIdx, { newWindow:id() })
			retile(state, targetScreenId, targetSpaceId)
			focusWindow(newWindow, function()
				addToWindowStack(newWindow)
				centerMouseInWindow(newWindow)
				hs.timer.doAfter(0.1, function()
					windowWatcherPaused = false
				end)
			end)
		end)
	end

	windowWatcherPaused = true

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

function WM:saveState()
	Settings.set("wm_two_state", serpent.dump(state))
end

function WM:init()
	local ok, savedState = serpent.load(Settings.get("wm_two_state") or "{ screens = {} }")
	state.windowStack = savedState.windowStack or state.windowStack
	state.windowStackIndex = savedState.windowStackIndex or state.windowStackIndex
	state.fullscreenOriginalWidth = savedState.fullscreenOriginalWidth or state.fullscreenOriginalWidth
	state.activeSpaceForScreen = savedState.activeSpaceForScreen or state.activeSpaceForScreen
	state.startXForScreenAndSpace = savedState.startXForScreenAndSpace or state.startXForScreenAndSpace

	-- Move spaces that belonged to monitors which are no longer connected onto the
	-- first currently-connected screen. This preserves the layout of those
	-- spaces between reloads instead of discarding them.
	do
		-- Build a set of screen ids that are actually present right now
		local connectedScreens = {}
		local availableScreens = Screen.allScreens()
		for _, scr in ipairs(availableScreens) do
			connectedScreens[scr:id()] = true
		end

		-- If there is at least one screen connected, use the first one as the
		-- destination for any orphaned spaces.
		local firstScreen = availableScreens[1]
		if firstScreen then
			local targetScreenId = firstScreen:id()

			-- Ensure the target screen has tables ready to receive moved data
			savedState.screens[targetScreenId] = savedState.screens[targetScreenId] or {}
			savedState.startXForScreenAndSpace = savedState.startXForScreenAndSpace or {}
			savedState.startXForScreenAndSpace[targetScreenId] = savedState.startXForScreenAndSpace[targetScreenId]
				or {}

			-- Identify screens present in the saved state that are no longer connected
			local orphanedScreenIds = {}
			for savedScreenId, _ in pairs(savedState.screens) do
				if not connectedScreens[savedScreenId] then
					table.insert(orphanedScreenIds, savedScreenId)
				end
			end

			-- Re-home each orphaned screen's spaces onto the target screen
			for _, orphanId in ipairs(orphanedScreenIds) do
				local orphanSpaces = savedState.screens[orphanId]
				for spaceId, spaceData in pairs(orphanSpaces) do
					-- Find the first unused space slot (1-9) on the target screen
					local destSpaceId = nil
					for i = 1, 9 do
						local existing = savedState.screens[targetScreenId][i]
						if not existing or (#(existing.cols or {}) == 0 and #(existing.floating or {}) == 0) then
							destSpaceId = i
							break
						end
					end
					-- If we found an open slot, move the space data and its stored X offset
					if destSpaceId then
						savedState.screens[targetScreenId][destSpaceId] = spaceData
						if
							savedState.startXForScreenAndSpace[orphanId]
							and savedState.startXForScreenAndSpace[orphanId][spaceId] ~= nil
						then
							savedState.startXForScreenAndSpace[targetScreenId][destSpaceId] =
								savedState.startXForScreenAndSpace[orphanId][spaceId]
						end
					end
				end
				-- Remove the orphaned screen so we do not reference it later
				savedState.screens[orphanId] = nil
				savedState.startXForScreenAndSpace[orphanId] = nil
			end
		end
	end

	local placements = {} -- window:id() -> { screenId, spaceId, colIdx, rowIdx, isFloating }
	for _, screen in ipairs(Screen.allScreens()) do
		local screenId = screen:id()
		local spaces = savedState.screens[screenId] or {}
		for spaceId, space in pairs(spaces) do
			for colIdx, col in ipairs(space.cols) do
				for rowIdx, winId in ipairs(col) do
					placements[winId] = { screenId = screenId, spaceId = spaceId, colIdx = colIdx, rowIdx = rowIdx }
				end
			end
		end
	end

	-- Re-build default structures for all screens/spaces
	for _, screen in ipairs(Screen.allScreens()) do
		local screenId = screen:id()
		state.activeSpaceForScreen[screenId] = state.activeSpaceForScreen[screenId] or 1
		state.startXForScreenAndSpace[screenId] = state.startXForScreenAndSpace[screenId] or {}
		state.screens[screenId] = state.screens[screenId] or {}
		for i = 1, 9 do
			if state.startXForScreenAndSpace[screenId][i] == nil then
				state.startXForScreenAndSpace[screenId][i] = 0
			end
			state.screens[screenId][i] = state.screens[screenId][i] or { cols = {}, floating = {} }
		end
	end

	local unplacedWindows = {}
	for _, app in ipairs(Application.runningApplications()) do
		for _, win in ipairs(app:allWindows()) do
			if win:isStandard() and win:isVisible() and not win:isFullScreen() then
				local id = win:id()
				local placed = placements[id]
				local screenId, spaceId, colIdx, rowIdx

				if placed then
					screenId = placed.screenId
					spaceId = placed.spaceId
					colIdx = placed.colIdx
					rowIdx = placed.rowIdx

					-- Ensure the space exists (might be a named space not initialized in the loop above)
					if not state.screens[screenId] then
						state.screens[screenId] = {}
					end
					if not state.screens[screenId][spaceId] then
						state.screens[screenId][spaceId] = { cols = {}, floating = {} }
						state.startXForScreenAndSpace[screenId] = state.startXForScreenAndSpace[screenId] or {}
						state.startXForScreenAndSpace[screenId][spaceId] = 0
					end

					state.screens[screenId][spaceId].cols[colIdx] = state.screens[screenId][spaceId].cols[colIdx] or {}
					state.screens[screenId][spaceId].cols[colIdx][rowIdx] = win:id()
				else
					table.insert(unplacedWindows, win)
				end
			end
		end
	end

	for _, win in ipairs(unplacedWindows) do
		local screen = win:screen()
		local screenId = screen and screen:id() or Screen.mainScreen():id()
		local spaceId = state.activeSpaceForScreen[screenId] or 1
		local colIdx = #state.screens[screenId][spaceId].cols + 1
		state.screens[screenId][spaceId].cols[colIdx] = state.screens[screenId][spaceId].cols[colIdx] or {}
		table.insert(state.screens[screenId][spaceId].cols[colIdx], win:id())
	end

	cleanWindowStack()

	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if state.activeSpaceForScreen[screenId] == spaceId then
				retile(state, screenId, spaceId)
			else
				moveSpaceWindowsOffscreen(screenId, spaceId)
			end
		end
	end

	-- Create menubar space indicator
	WM._menubar = hs.menubar.new()
	updateMenubar()

	-- Create command palette (fuzzy finder for commands and spaces)
	WM._commandPalette = hs.chooser.new(function(choice)
		if not choice then
			-- Reset to root mode when dismissed
			commandPaletteMode = "root"
			-- Explicitly hide the chooser
			WM._commandPalette:hide()
			return
		end

		-- Handle space actions (final actions that close the palette)
		local actionType = choice.actionType
		local targetScreenId = choice.screenId
		local targetSpaceId = choice.spaceId

		if actionType == "createAndSwitchSpace" then
			-- Create the new space
			WM:createSpace(targetSpaceId, targetScreenId)

			-- If different screen, move mouse there first
			local currentScreen = Mouse.getCurrentScreen()
			if currentScreen:id() ~= targetScreenId then
				local targetScreen = Screen(targetScreenId)
				local frame = targetScreen:frame()
				Mouse.absolutePosition({ x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
			end

			-- Switch to the space
			WM:switchToSpace(targetSpaceId)
		elseif actionType == "switchSpace" then
			-- If different screen, move mouse there first
			local currentScreen = Mouse.getCurrentScreen()
			if currentScreen:id() ~= targetScreenId then
				local targetScreen = Screen(targetScreenId)
				local frame = targetScreen:frame()
				Mouse.absolutePosition({ x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
			end

			-- Switch to the space
			WM:switchToSpace(targetSpaceId)
		elseif actionType == "moveWindowToSpace" then
			-- Move focused window to the selected space
			WM:moveFocusedWindowToSpace(targetSpaceId)
		end

		-- Reset to root mode after completing an action
		commandPaletteMode = "root"
	end)

	-- Handle invalid choices (valid=false) - keeps chooser open for navigation
	WM._commandPalette:invalidCallback(function(choice)
		if not choice then
			return
		end

		local actionType = choice.actionType

		-- Handle navigation actions (switch modes without closing)
		if actionType == "navigateToMoveWindow" then
			print("[commandPalette] Navigating to moveWindowToSpace mode")
			commandPaletteMode = "moveWindowToSpace"
			WM._commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			WM._commandPalette:choices(choices)
		end
	end)

	-- Disable built-in filtering since we handle it in queryChangedCallback
	WM._commandPalette:queryChangedCallback(function(query)
		local choices = buildCommandPaletteChoices(query)
		WM._commandPalette:choices(choices)
	end)

	-- Set background color to make the chooser more visible
	WM._commandPalette:bgDark(true)

	addToWindowStack(Window.focusedWindow())

	-- Watch for screen configuration changes (connect/disconnect)
	WM._screenWatcher = hs.screen.watcher.new(function()
		print("[screenWatcher] Screen configuration changed, reinitializing WM...")

		-- Save current state before reinitializing
		WM:saveState()

		-- Reinitialize to handle new screen configuration
		WM:init()

		print("[screenWatcher] Reinitialization complete")
	end)
	WM._screenWatcher:start()
end

hs.hotkey.bind({ "cmd", "ctrl" }, "t", function()
	print(hs.inspect(state.screens))
end)

return WM
