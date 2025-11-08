local Tiling = {}

-- Dependencies
local State
local Windows

-- Hammerspoon imports
local Screen <const> = hs.screen
local Window <const> = hs.window

-- Configuration (will be set via init)
local tileGap = 10

-- Get state reference
local state

------------------------------------------
-- Screen utilities
------------------------------------------

-- Get the rightmost screen
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

------------------------------------------
-- Offscreen management
------------------------------------------

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
		local win = Windows.getWindow(winId)
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

------------------------------------------
-- Core retiling logic
------------------------------------------

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
			local win = Windows.getWindow(winId)
			if win then
				local frame = win:frame()
				if frame.w > maxColWidth then
					maxColWidth = frame.w
				end
			end
		end

		-- Calculate the height each window should have to fill the column
		local n = #col
		local totalGap = tileGap * (n - 1)
		local availableHeight = screenFrame.h - totalGap
		local baseHeight = math.floor(availableHeight / n)
		local remainder = availableHeight - (baseHeight * n) -- Distribute remainder pixels

		local colX = currentX
		local rowY = y
		for jdx, winId in ipairs(col) do
			local win = Windows.getWindow(winId)
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

				rowY = rowY + targetFrame.h + tileGap
				if winId == focusedWindowId then
					targetColIdx = idx
				end
			end
		end
		currentX = currentX + maxColWidth + tileGap
	end

	-- Phase 2: Process visible windows first (user sees these immediately)
	if not opts.onlyOffscreen then
		for _, update in ipairs(visibleUpdates) do
			if Windows.framesDiffer(update.currentFrame, update.targetFrame) then
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
			if Windows.framesDiffer(update.currentFrame, update.targetFrame) then
				if opts.duration then
					update.win:setFrame(update.targetFrame, opts.duration)
				else
					update.win:setFrame(update.targetFrame)
				end
			end
		end
	end
end

------------------------------------------
-- Bring window into view
------------------------------------------

local function bringIntoView(win)
	if not win then
		return
	end
	local screenId, spaceId, colIdx, rowIdx = Windows.locateWindow(win:id())
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
		local w = Windows.getWindow(winId)
		if w then
			preWidth = preWidth + w:frame().w + tileGap
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
-- Retile all screens
------------------------------------------

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

------------------------------------------
-- Public API
------------------------------------------

function Tiling.init(wm)
	-- Get references to dependencies
	State = wm.State
	Windows = wm.Windows

	-- Get state reference
	state = State.get()

	-- Get configuration
	tileGap = wm.tileGap

	print("[Tiling] Initialized")
end

function Tiling.retile(screenId, spaceId, opts)
	return retile(state, screenId, spaceId, opts)
end

function Tiling.retileAll(opts)
	return retileAll(opts)
end

function Tiling.bringIntoView(win)
	return bringIntoView(win)
end

function Tiling.moveSpaceWindowsOffscreen(screenId, spaceId, opts)
	return moveSpaceWindowsOffscreen(screenId, spaceId, opts)
end

function Tiling.getRightmostScreen()
	return getRightmostScreen()
end

return Tiling
