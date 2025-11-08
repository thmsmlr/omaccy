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

-- Load submodules
WM.State = dofile(hs.configdir .. "/wm/state.lua")

-- Get state reference from State module
local _windows = {}
local state = WM.State.get()

-- Command palette state (not persisted)
local commandPaletteMode = "root" -- "root" or "moveWindowToSpace"
local previousChoicesCount = 0

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
local updateMenubar
local buildCommandPaletteChoices

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
				updateMenubar()

				-- Refresh command palette if it's visible
				if WM._commandPalette and WM._commandPalette:isVisible() then
					local currentQuery = WM._commandPalette:query()
					local choices = buildCommandPaletteChoices(currentQuery)
					WM._commandPalette:choices(choices)
				end
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
	local _, _, focusedColIdx = locateWindow(focusedWindowId)
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
			local w = getWindow(id)
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

	-- Always clip at 50% for symmetric coverflow-style effect
	local function getClipMargin(windowWidth)
		return windowWidth / 2
	end

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
				local clipMargin = getClipMargin(maxColWidth)
				local targetFrame = {
					x = math.min(
						math.max(colX, screenFrame.x - clipMargin + 1),
						screenFrame.x + screenFrame.w - clipMargin - 1
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
	if not screenId or not spaceId or not colIdx then
		return
	end

	local screen = Screen(screenId)
	if not screen then
		return
	end
	local screenFrame = screen:frame()

	-- Total width (plus gaps) before the target window in the stack
	local preWidth = 0
	for i = 1, colIdx - 1 do
		local winId = state.screens[screenId][spaceId].cols[i][1]
		local w = getWindow(winId)
		if w then
			preWidth = preWidth + w:frame().w + WM.tileGap
		end
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

------------------------------------------
-- Urgency helpers
------------------------------------------

-- Get all urgent windows in a specific space
local function getUrgentWindowsInSpace(screenId, spaceId)
	local urgentWindows = {}
	if not state.screens[screenId] or not state.screens[screenId][spaceId] then
		return urgentWindows
	end

	local space = state.screens[screenId][spaceId]
	-- Check tiled windows
	for _, col in ipairs(space.cols or {}) do
		for _, winId in ipairs(col) do
			if state.urgentWindows[winId] then
				table.insert(urgentWindows, winId)
			end
		end
	end

	-- Check floating windows
	for _, winId in ipairs(space.floating or {}) do
		if state.urgentWindows[winId] then
			table.insert(urgentWindows, winId)
		end
	end

	return urgentWindows
end

-- Check if a space has any urgent windows
local function isSpaceUrgent(screenId, spaceId)
	return #getUrgentWindowsInSpace(screenId, spaceId) > 0
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

-- Returns the (screenId, spaceId) for a given window ID, or nil if not found
local function getSpaceForWindow(winId)
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if space.cols then
				for _, col in ipairs(space.cols) do
					for _, id in ipairs(col) do
						if id == winId then
							return screenId, spaceId
						end
					end
				end
			end
			if space.floating then
				for _, id in ipairs(space.floating) do
					if id == winId then
						return screenId, spaceId
					end
				end
			end
		end
	end
	return nil, nil
end

-- Derives space MRU order from the window stack
-- Returns an array of {screenId, spaceId} pairs, ordered by most recently used
local function getSpaceMRUOrder()
	local seen = {}
	local order = {}

	for _, winId in ipairs(state.windowStack) do
		local screenId, spaceId = getSpaceForWindow(winId)
		if spaceId then
			local key = screenId .. ":" .. spaceId
			if not seen[key] then
				seen[key] = true
				table.insert(order, {screenId = screenId, spaceId = spaceId})
			end
		end
	end

	return order
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
	-- This determines whether to show the "Create space" option
	local queryMatchesExisting = false
	if query ~= "" then
		local lowerQuery = string.lower(query)

		-- Check if query is a numbered space (exact match for numbers)
		local queryNum = tonumber(query)
		if queryNum then
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
		end

		-- Check if query matches any named space (prefix/substring match)
		if not queryMatchesExisting then
			for _, screen in ipairs(screens) do
				local screenId = screen:id()
				if state.screens[screenId] then
					for spaceId, space in pairs(state.screens[screenId]) do
						if type(spaceId) == "string" then
							local hasWindows = (space.cols and #space.cols > 0) or (space.floating and #space.floating > 0)
							if hasWindows then
								local lowerSpaceName = string.lower(spaceId)
								-- Check if query is a prefix or substring
								if lowerSpaceName:find(lowerQuery, 1, true) then
									queryMatchesExisting = true
									break
								end
							end
						end
					end
					if queryMatchesExisting then
						break
					end
				end
			end
		end
	end

	-- Add "Create space" option if query doesn't match and isn't empty
	if query ~= "" and not queryMatchesExisting then
		local currentScreen = Mouse.getCurrentScreen()
		if actionType == "switchSpace" then
			table.insert(choices, {
				text = "+ Create space: " .. query,
				subText = "Create new named space and switch to it",
				screenId = currentScreen:id(),
				spaceId = query,
				actionType = "createAndSwitchSpace",
			})
		elseif actionType == "moveWindowToSpace" then
			table.insert(choices, {
				text = "+ Create space: " .. query,
				subText = "Create new named space and move focused window to it",
				screenId = currentScreen:id(),
				spaceId = query,
				actionType = "createAndMoveWindowToSpace",
			})
		end
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
				local isUrgent = isSpaceUrgent(screenId, spaceId)

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

				-- Prefix with urgency indicator
				if isUrgent then
					text = "● " .. text
				end

				table.insert(choices, {
					text = text,
					subText = subText,
					screenId = screenId,
					spaceId = spaceId,
					isCurrent = isCurrent,
					isUrgent = isUrgent,
					actionType = actionType,
				})

				::continue::
			end
		end
	end

	-- Fuzzy matching function: checks if all characters in query appear in order in text
	-- Returns score (higher is better) or nil if no match
	local function fuzzyMatch(query, text)
		if query == "" then
			return 0
		end

		local lowerQuery = string.lower(query)
		local lowerText = string.lower(text)
		local queryLen = #lowerQuery
		local textLen = #lowerText
		local score = 0
		local queryIdx = 1
		local lastMatchIdx = 0
		local consecutiveMatches = 0

		-- Check if all query characters appear in order
		for textIdx = 1, textLen do
			if queryIdx > queryLen then
				break
			end

			local queryChar = lowerQuery:sub(queryIdx, queryIdx)
			local textChar = lowerText:sub(textIdx, textIdx)

			if queryChar == textChar then
				-- Character match found
				local isPrefix = (queryIdx == 1 and textIdx == 1)
				local isConsecutive = (textIdx == lastMatchIdx + 1)
				local isCaseMatch = (query:sub(queryIdx, queryIdx) == text:sub(textIdx, textIdx))

				-- Calculate score
				score = score + 100 -- base score for match

				if isPrefix then
					score = score + 200 -- big bonus for prefix match
				end

				if isConsecutive then
					consecutiveMatches = consecutiveMatches + 1
					score = score + (50 * consecutiveMatches) -- bonus for consecutive matches
				else
					consecutiveMatches = 0
				end

				if isCaseMatch then
					score = score + 10 -- small bonus for case match
				end

				-- Bonus for matches earlier in the string
				score = score + (100 - textIdx)

				lastMatchIdx = textIdx
				queryIdx = queryIdx + 1
			end
		end

		-- Return score if all query characters were matched
		if queryIdx > queryLen then
			return score
		else
			return nil
		end
	end

	-- Filter and score choices based on fuzzy matching
	if query ~= "" then
		local filtered = {}

		for _, choice in ipairs(choices) do
			-- Always include the create action
			if choice.actionType == "createAndSwitchSpace" then
				choice.score = math.huge -- Always at top
				table.insert(filtered, choice)
			else
				-- Try fuzzy matching against text and subtext
				local textScore = fuzzyMatch(query, choice.text)
				local subTextScore = choice.subText and fuzzyMatch(query, choice.subText) or nil

				-- Use the better score
				local bestScore = nil
				if textScore and subTextScore then
					bestScore = math.max(textScore, subTextScore)
				elseif textScore then
					bestScore = textScore
				elseif subTextScore then
					bestScore = subTextScore
				end

				if bestScore then
					choice.score = bestScore
					table.insert(filtered, choice)
				end
			end
		end
		choices = filtered
	else
		-- No query: assign scores for default sorting
		for _, choice in ipairs(choices) do
			choice.score = 0
		end
	end

	-- Compute MRU order from window stack and assign mruIndex to each choice
	local spaceMRU = getSpaceMRUOrder()
	for _, choice in ipairs(choices) do
		-- Find this space in the MRU order
		local mruIndex = nil
		for i, space in ipairs(spaceMRU) do
			if space.screenId == choice.screenId and space.spaceId == choice.spaceId then
				mruIndex = i
				break
			end
		end
		choice.mruIndex = mruIndex or math.huge -- Spaces not in MRU go to the end
	end

	-- Sort: by fuzzy match score (highest first), then urgency, then MRU order, then current space last
	table.sort(choices, function(a, b)
		-- Compare scores (higher score = better match, should come first)
		local aScore = a.score or 0
		local bScore = b.score or 0

		if aScore ~= bScore then
			return aScore > bScore -- higher score first
		end

		-- If scores are equal, urgent spaces come first
		if a.isUrgent ~= b.isUrgent then
			return a.isUrgent
		end

		-- Current space comes last (non-current spaces come first)
		if a.isCurrent ~= b.isCurrent then
			return b.isCurrent -- if b is current, a comes first (puts current at end)
		end

		-- Then by MRU order (lower index = more recent = comes first)
		local aMRU = a.mruIndex or math.huge
		local bMRU = b.mruIndex or math.huge

		return aMRU < bMRU
	end)

	return choices
end

local function buildCommandPaletteChoices(query)
	query = query or ""

	if commandPaletteMode == "root" then
		-- Root menu: show spaces directly for switching, plus additional commands
		local choices = buildSpaceList(query, "switchSpace")

		-- Add "Rename space" command
		table.insert(choices, {
			text = "Rename space",
			subText = "Rename the current space",
			actionType = "navigateToRenameSpace",
			valid = false, -- Don't close chooser when selected
		})

		-- Add "Move window to space" command
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
	elseif commandPaletteMode == "renameSpace" then
		-- Show option to rename current space to the query
		local choices = {}

		-- Get current space info
		local currentScreen = Mouse.getCurrentScreen()
		local currentScreenId = currentScreen:id()
		local currentSpaceId = state.activeSpaceForScreen[currentScreenId]

		if query ~= "" then
			-- Show "Rename to: {query}" option
			table.insert(choices, {
				text = "Rename to: " .. query,
				subText = "Rename current space '" .. tostring(currentSpaceId) .. "' to '" .. query .. "'",
				actionType = "renameSpace",
				newSpaceId = query,
				oldSpaceId = currentSpaceId,
				screenId = currentScreenId,
			})
		else
			-- Show instruction when no query
			table.insert(choices, {
				text = "Type new name for space '" .. tostring(currentSpaceId) .. "'",
				subText = "Current space will be renamed",
				actionType = "instruction",
				valid = false,
			})
		end

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

	-- Add asterisk prefix if any windows are marked urgent
	local hasUrgent = false
	for _, _ in pairs(state.urgentWindows) do
		hasUrgent = true
		break
	end
	if hasUrgent then
		title = "* " .. title
	end

	-- Create menu for switching spaces on the current screen
	local currentScreen = Mouse.getCurrentScreen()
	local currentScreenId = currentScreen:id()
	local currentSpaceId = state.activeSpaceForScreen[currentScreenId] or 1

	local menu = {}

	-- Collect all spaces on the current screen that have windows
	local spacesWithWindows = {}
	if state.screens[currentScreenId] then
		for spaceId, space in pairs(state.screens[currentScreenId]) do
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

			-- Only include spaces that have windows
			if windowCount > 0 then
				table.insert(spacesWithWindows, spaceId)
			end
		end
	end

	-- Sort spaces: numbers first, then strings alphabetically
	table.sort(spacesWithWindows, function(a, b)
		local aIsNum = type(a) == "number"
		local bIsNum = type(b) == "number"
		if aIsNum ~= bIsNum then
			return aIsNum -- numbers before strings
		end
		return tostring(a) < tostring(b)
	end)

	-- Build menu items
	for _, spaceId in ipairs(spacesWithWindows) do
		local checked = (spaceId == currentSpaceId)
		local title
		if type(spaceId) == "string" then
			title = spaceId -- Named space: show the name
		else
			title = "Space " .. spaceId -- Numbered space
		end

		table.insert(menu, {
			title = title,
			checked = checked,
			fn = function()
				WM:switchToSpace(spaceId)
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

	-- Clean window stack before building choices to ensure fresh MRU data
	cleanWindowStack()

	-- Refresh choices when showing
	local choices = buildCommandPaletteChoices()
	WM._commandPalette:choices(choices)
	previousChoicesCount = #choices
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

	-- Clear urgency for focused window
	local winId = win:id()
	if state.urgentWindows[winId] then
		state.urgentWindows[winId] = nil
		print("[urgency] Cleared urgency for window " .. winId)
		updateMenubar()

		-- Refresh command palette if it's visible
		if WM._commandPalette and WM._commandPalette:isVisible() then
			local currentQuery = WM._commandPalette:query()
			local choices = buildCommandPaletteChoices(currentQuery)
			WM._commandPalette:choices(choices)
		end
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
	if not screenId or not spaceId or not colIdx then
		return
	end

	local screen = Screen(screenId)
	if not screen then
		return
	end
	local screenFrame = screen:frame()

	local preWidth = 0
	for i = 1, colIdx - 1 do
		local w = getWindow(state.screens[screenId][spaceId].cols[i][1])
		if w then
			preWidth = preWidth + w:frame().w + WM.tileGap
		end
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
		-- Bring window into view BEFORE focusing, so macOS can actually focus it
		bringIntoView(nextWindow)

		focusWindow(nextWindow, function()
			addToWindowStack(nextWindow)
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

function WM:renameSpace(screenId, oldSpaceId, newSpaceId)
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

	-- Don't allow renaming numbered spaces (1-4)
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
	self:saveState()

	print("[renameSpace]", "Successfully renamed space to:", newSpaceId)
end

------------------------------------------
-- Urgency methods
------------------------------------------

function WM:setWindowUrgent(winId, urgent)
	if urgent then
		state.urgentWindows[winId] = true
		print("[urgency] Window " .. winId .. " marked urgent")
	else
		state.urgentWindows[winId] = nil
		print("[urgency] Window " .. winId .. " urgency cleared")
	end
	updateMenubar()

	-- Refresh command palette if it's visible
	if WM._commandPalette and WM._commandPalette:isVisible() then
		local currentQuery = WM._commandPalette:query()
		local choices = buildCommandPaletteChoices(currentQuery)
		WM._commandPalette:choices(choices)
	end
end

function WM:clearWindowUrgent(winId)
	self:setWindowUrgent(winId, false)
end

function WM:debugUrgentWindows()
	print("=== Urgent Windows Debug ===")
	for winId, _ in pairs(state.urgentWindows) do
		local win = getWindow(winId)
		if win then
			print(string.format("  Window %d: %s (exists)", winId, win:title()))
		else
			print(string.format("  Window %d: (DEAD WINDOW)", winId))
		end
	end
	print("===========================")
end

function WM:setCurrentWindowUrgent()
	local win = Window.focusedWindow()
	if win then
		self:setWindowUrgent(win:id(), true)
	end
end

function WM:setUrgentByApp(appName)
	local app = Application.get(appName)
	if not app then
		print("[urgency] Application not found: " .. appName)
		return
	end

	local count = 0
	for _, win in ipairs(app:allWindows()) do
		if win:isStandard() and win:isVisible() then
			self:setWindowUrgent(win:id(), true)
			count = count + 1
		end
	end
	print("[urgency] Marked " .. count .. " windows urgent for app: " .. appName)
end

function WM:clearAllUrgent()
	state.urgentWindows = {}
	print("[urgency] Cleared all urgent windows")
	updateMenubar()
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
	WM.State.save()
end

-- Setup UI components (menubar and command palette)
local function setupUI()
	-- Create menubar space indicator
	WM._menubar = hs.menubar.new()
	updateMenubar()

	-- Create command palette (fuzzy finder for commands and spaces)
	WM._commandPalette = hs.chooser.new(function(choice)
		if not choice then
			commandPaletteMode = "root"
			WM._commandPalette:hide()
			return
		end

		local actionType = choice.actionType
		local targetScreenId = choice.screenId
		local targetSpaceId = choice.spaceId

		if actionType == "createAndSwitchSpace" then
			WM:createSpace(targetSpaceId, targetScreenId)
			local currentScreen = Mouse.getCurrentScreen()
			if currentScreen:id() ~= targetScreenId then
				local targetScreen = Screen(targetScreenId)
				local frame = targetScreen:frame()
				Mouse.absolutePosition({ x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
			end
			WM:switchToSpace(targetSpaceId)
		elseif actionType == "createAndMoveWindowToSpace" then
			WM:createSpace(targetSpaceId, targetScreenId)
			WM:moveFocusedWindowToSpace(targetSpaceId)
		elseif actionType == "switchSpace" then
			local currentScreen = Mouse.getCurrentScreen()
			if currentScreen:id() ~= targetScreenId then
				local targetScreen = Screen(targetScreenId)
				local frame = targetScreen:frame()
				Mouse.absolutePosition({ x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 })
			end
			WM:switchToSpace(targetSpaceId)
		elseif actionType == "moveWindowToSpace" then
			WM:moveFocusedWindowToSpace(targetSpaceId)
		elseif actionType == "renameSpace" then
			WM:renameSpace(choice.screenId, choice.oldSpaceId, choice.newSpaceId)
		end

		commandPaletteMode = "root"
	end)

	WM._commandPalette:invalidCallback(function(choice)
		if not choice then
			return
		end

		local actionType = choice.actionType
		if actionType == "navigateToMoveWindow" then
			print("[commandPalette] Navigating to moveWindowToSpace mode")
			commandPaletteMode = "moveWindowToSpace"
			WM._commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			WM._commandPalette:choices(choices)
		elseif actionType == "navigateToRenameSpace" then
			print("[commandPalette] Navigating to renameSpace mode")
			commandPaletteMode = "renameSpace"
			WM._commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			WM._commandPalette:choices(choices)
		end
	end)

	WM._commandPalette:queryChangedCallback(function(query)
		local choices = buildCommandPaletteChoices(query)
		WM._commandPalette:choices(choices)

		-- Reset selection to first item if results changed
		if #choices ~= previousChoicesCount then
			WM._commandPalette:selectedRow(1)
			previousChoicesCount = #choices
		end
	end)

	WM._commandPalette:bgDark(true)
end

function WM:init()
	print("[init] Starting window manager initialization")

	-- 1. Initialize State module (handles loading, cleaning, migration, reconciliation)
	WM.State.init(WM)

	-- 2. Clean window stack
	cleanWindowStack()

	-- 3. Retile all spaces
	print("[init] Retiling all spaces")
	for screenId, spaces in pairs(state.screens) do
		for spaceId, space in pairs(spaces) do
			if state.activeSpaceForScreen[screenId] == spaceId then
				retile(state, screenId, spaceId)
			else
				moveSpaceWindowsOffscreen(screenId, spaceId)
			end
		end
	end

	-- 4. Setup UI
	setupUI()

	-- 5. Add focused window to stack
	addToWindowStack(Window.focusedWindow())

	print("[init] Initialization complete")
end

hs.hotkey.bind({ "cmd", "ctrl" }, "t", function()
	print(hs.inspect(state.screens))
end)

return WM
