--[[
Expose Module

Custom exposé implementation for virtual spaces.
Shows window thumbnails for quick switching within the current virtual space.

Features:
- Background snapshot caching for instant display
- Custom canvas-based UI with window previews
- Keyboard hints (A-Z) for quick selection
- Mouse click support
- Scoped to current virtual space only
]]

local Expose = {}

-- Dependencies (set during init)
local WM = nil
local state = nil
local Windows = nil
local Tiling = nil

-- Configuration
local SNAPSHOT_INTERVAL = 5.0       -- seconds between background snapshot updates
local SNAPSHOT_STALE_TIME = 30.0    -- seconds before a snapshot is considered stale
local SNAPSHOT_ACTIVE_TIME = 10.0   -- seconds - windows active within this time get priority
local THUMBNAIL_PADDING = 20        -- pixels between thumbnails
local THUMBNAIL_MAX_WIDTH = 300
local THUMBNAIL_MAX_HEIGHT = 200
local LABEL_HEIGHT = 24
local HINT_SIZE = 32
local OVERLAY_ALPHA = 0.85
local HINT_CHARS = "ASDFGHJKLQWERTYUIOPZXCVBNM"

-- State
local snapshotCache = {}  -- windowId -> { image = hs.image, timestamp = number }
local lastActiveTime = {} -- windowId -> timestamp when window was last focused
local snapshotTimer = nil
local canvas = nil
local isVisible = false
local currentWindows = {}  -- array of { winId, win, hint, bounds }
local keyWatcher = nil

------------------------------------------
-- Snapshot Management
------------------------------------------

-- Capture snapshot for a single window
local function captureSnapshot(winId)
	local win = Windows.getWindow(winId)
	if not win then
		return nil
	end

	local snapshot = win:snapshot()
	if snapshot then
		snapshotCache[winId] = {
			image = snapshot,
			timestamp = hs.timer.secondsSinceEpoch(),
		}
		return snapshot
	end
	return nil
end

-- Get window IDs in active (visible) spaces only - these can be snapshotted
local function getVisibleWindowIds()
	local windowIds = {}
	for screenId, spaces in pairs(state.screens or {}) do
		local activeSpaceId = state.activeSpaceForScreen[screenId]
		if activeSpaceId and spaces[activeSpaceId] then
			local space = spaces[activeSpaceId]
			-- Tiled windows
			for _, col in ipairs(space.cols or {}) do
				for _, winId in ipairs(col) do
					table.insert(windowIds, winId)
				end
			end
			-- Floating windows
			if space.floating then
				for _, winId in ipairs(space.floating) do
					table.insert(windowIds, winId)
				end
			end
		end
	end
	return windowIds
end

-- Get all window IDs across all spaces (for cache cleanup)
local function getAllTrackedWindowIds()
	local windowIds = {}
	for screenId, spaces in pairs(state.screens or {}) do
		for spaceId, space in pairs(spaces) do
			-- Tiled windows
			for _, col in ipairs(space.cols or {}) do
				for _, winId in ipairs(col) do
					table.insert(windowIds, winId)
				end
			end
			-- Floating windows
			if space.floating then
				for _, winId in ipairs(space.floating) do
					table.insert(windowIds, winId)
				end
			end
		end
	end
	return windowIds
end

-- Background snapshot update
-- Smart strategy: prioritize recently active windows, be lazy about inactive ones
local function updateSnapshots()
	local visibleWindowIds = getVisibleWindowIds()
	local allWindowIds = getAllTrackedWindowIds()
	local now = hs.timer.secondsSinceEpoch()

	for _, winId in ipairs(visibleWindowIds) do
		local cached = snapshotCache[winId]
		local lastActive = lastActiveTime[winId] or 0
		local timeSinceActive = now - lastActive
		local timeSinceCached = cached and (now - cached.timestamp) or math.huge

		-- Determine if we should update this window's snapshot:
		-- 1. No cached snapshot yet - always capture
		-- 2. Recently active (within SNAPSHOT_ACTIVE_TIME) - update frequently
		-- 3. Not recently active - only update if snapshot is stale
		local shouldUpdate = false

		if not cached then
			-- No snapshot yet, capture it
			shouldUpdate = true
		elseif timeSinceActive < SNAPSHOT_ACTIVE_TIME then
			-- Recently active window - update if cache is older than interval
			shouldUpdate = timeSinceCached > SNAPSHOT_INTERVAL
		else
			-- Inactive window - only update if really stale
			shouldUpdate = timeSinceCached > SNAPSHOT_STALE_TIME
		end

		if shouldUpdate then
			captureSnapshot(winId)
		end
	end

	-- Clean up stale cache entries (windows that no longer exist)
	local validIds = {}
	for _, winId in ipairs(allWindowIds) do
		validIds[winId] = true
	end
	for winId, _ in pairs(snapshotCache) do
		if not validIds[winId] then
			snapshotCache[winId] = nil
			lastActiveTime[winId] = nil
		end
	end
end

-- Mark a window as recently active (call this when window is focused)
function Expose.markWindowActive(winId)
	if winId then
		lastActiveTime[winId] = hs.timer.secondsSinceEpoch()
	end
end

-- Start background snapshot timer
local function startSnapshotTimer()
	if snapshotTimer then
		snapshotTimer:stop()
	end

	-- Initial capture
	updateSnapshots()

	-- Periodic updates
	snapshotTimer = hs.timer.doEvery(SNAPSHOT_INTERVAL, function()
		if not isVisible then  -- Don't update while expose is showing
			updateSnapshots()
		end
	end)
end

-- Stop background snapshot timer
local function stopSnapshotTimer()
	if snapshotTimer then
		snapshotTimer:stop()
		snapshotTimer = nil
	end
end

------------------------------------------
-- Layout Calculation
------------------------------------------

-- Calculate horizontal linear layout for thumbnails (mirrors the scrolling WM)
local function calculateLayout(windows, screenFrame)
	local count = #windows
	if count == 0 then
		return {}
	end

	-- Target height for thumbnails (leave room for padding and labels)
	local availableHeight = screenFrame.h - (THUMBNAIL_PADDING * 2) - LABEL_HEIGHT - 60  -- 60 for instructions
	local targetHeight = math.min(availableHeight * 0.7, THUMBNAIL_MAX_HEIGHT)

	-- First pass: calculate widths based on aspect ratios
	local thumbnailInfos = {}
	local totalWidth = 0

	for i, winInfo in ipairs(windows) do
		local aspectRatio = 16 / 9  -- default aspect ratio

		-- Try to get actual aspect ratio from cached snapshot or window frame
		local cached = snapshotCache[winInfo.winId]
		if cached and cached.image then
			local imgSize = cached.image:size()
			if imgSize.w > 0 and imgSize.h > 0 then
				aspectRatio = imgSize.w / imgSize.h
			end
		else
			-- Fallback to window frame
			local win = winInfo.win
			if win then
				local frame = win:frame()
				if frame.w > 0 and frame.h > 0 then
					aspectRatio = frame.w / frame.h
				end
			end
		end

		local thumbWidth = targetHeight * aspectRatio
		thumbnailInfos[i] = {
			winInfo = winInfo,
			aspectRatio = aspectRatio,
			width = thumbWidth,
			height = targetHeight,
		}
		totalWidth = totalWidth + thumbWidth
	end

	-- Add padding between thumbnails
	totalWidth = totalWidth + (THUMBNAIL_PADDING * (count - 1))

	-- Scale down if total width exceeds screen
	local maxWidth = screenFrame.w - (THUMBNAIL_PADDING * 2)
	local scale = 1
	if totalWidth > maxWidth then
		scale = maxWidth / totalWidth
	end

	-- Apply scale
	totalWidth = 0
	for i, info in ipairs(thumbnailInfos) do
		info.width = info.width * scale
		info.height = info.height * scale
		totalWidth = totalWidth + info.width
	end
	totalWidth = totalWidth + (THUMBNAIL_PADDING * (count - 1))

	-- Center the row vertically and horizontally
	local startX = screenFrame.x + (screenFrame.w - totalWidth) / 2
	local startY = screenFrame.y + (screenFrame.h - thumbnailInfos[1].height - LABEL_HEIGHT) / 2

	-- Calculate bounds for each window
	local layout = {}
	local currentX = startX

	for i, info in ipairs(thumbnailInfos) do
		layout[i] = {
			winId = info.winInfo.winId,
			win = info.winInfo.win,
			hint = HINT_CHARS:sub(i, i),
			bounds = {
				x = currentX,
				y = startY,
				w = info.width,
				h = info.height,
			},
			labelBounds = {
				x = currentX,
				y = startY + info.height,
				w = info.width,
				h = LABEL_HEIGHT,
			},
		}
		currentX = currentX + info.width + THUMBNAIL_PADDING
	end

	return layout
end

------------------------------------------
-- Canvas Rendering
------------------------------------------

-- Create and show the expose canvas
local function showCanvas(windows, screenFrame)
	if canvas then
		canvas:delete()
	end

	canvas = hs.canvas.new(screenFrame)

	-- Background overlay
	canvas:appendElements({
		type = "rectangle",
		fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = OVERLAY_ALPHA },
		frame = { x = 0, y = 0, w = screenFrame.w, h = screenFrame.h },
	})

	-- Calculate layout
	currentWindows = calculateLayout(windows, screenFrame)

	-- Render each window thumbnail
	for i, winInfo in ipairs(currentWindows) do
		local bounds = winInfo.bounds
		local labelBounds = winInfo.labelBounds
		local cached = snapshotCache[winInfo.winId]

		-- Thumbnail background
		canvas:appendElements({
			type = "rectangle",
			fillColor = { red = 0.2, green = 0.2, blue = 0.2, alpha = 1 },
			strokeColor = { red = 0.4, green = 0.4, blue = 0.4, alpha = 1 },
			strokeWidth = 2,
			roundedRectRadii = { xRadius = 8, yRadius = 8 },
			frame = {
				x = bounds.x - screenFrame.x,
				y = bounds.y - screenFrame.y,
				w = bounds.w,
				h = bounds.h,
			},
		})

		-- Window snapshot
		if cached and cached.image then
			local imgSize = cached.image:size()
			local scale = math.min(
				(bounds.w - 8) / imgSize.w,
				(bounds.h - 8) / imgSize.h
			)
			local scaledW = imgSize.w * scale
			local scaledH = imgSize.h * scale
			local imgX = bounds.x - screenFrame.x + (bounds.w - scaledW) / 2
			local imgY = bounds.y - screenFrame.y + (bounds.h - scaledH) / 2

			canvas:appendElements({
				type = "image",
				image = cached.image,
				frame = {
					x = imgX,
					y = imgY,
					w = scaledW,
					h = scaledH,
				},
			})
		else
			-- Placeholder if no snapshot
			canvas:appendElements({
				type = "text",
				text = "No Preview",
				textColor = { red = 0.5, green = 0.5, blue = 0.5, alpha = 1 },
				textAlignment = "center",
				textSize = 14,
				frame = {
					x = bounds.x - screenFrame.x,
					y = bounds.y - screenFrame.y + bounds.h / 2 - 10,
					w = bounds.w,
					h = 20,
				},
			})
		end

		-- Hint letter (top-left corner)
		canvas:appendElements({
			type = "rectangle",
			fillColor = { red = 0.2, green = 0.5, blue = 0.9, alpha = 0.9 },
			roundedRectRadii = { xRadius = 4, yRadius = 4 },
			frame = {
				x = bounds.x - screenFrame.x + 4,
				y = bounds.y - screenFrame.y + 4,
				w = HINT_SIZE,
				h = HINT_SIZE,
			},
		})
		canvas:appendElements({
			type = "text",
			text = winInfo.hint,
			textColor = { red = 1, green = 1, blue = 1, alpha = 1 },
			textAlignment = "center",
			textFont = "Helvetica Bold",
			textSize = 18,
			frame = {
				x = bounds.x - screenFrame.x + 4,
				y = bounds.y - screenFrame.y + 8,
				w = HINT_SIZE,
				h = HINT_SIZE,
			},
		})

		-- Window title label
		local title = winInfo.win:title() or "Untitled"
		local app = winInfo.win:application()
		local appName = app and app:name() or ""
		local label = appName .. (title ~= "" and (" - " .. title) or "")
		if #label > 40 then
			label = label:sub(1, 37) .. "..."
		end

		canvas:appendElements({
			type = "text",
			text = label,
			textColor = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
			textAlignment = "center",
			textSize = 12,
			frame = {
				x = labelBounds.x - screenFrame.x,
				y = labelBounds.y - screenFrame.y + 4,
				w = labelBounds.w,
				h = labelBounds.h,
			},
		})
	end

	-- Instructions at bottom
	canvas:appendElements({
		type = "text",
		text = "Press a letter to select • Escape to cancel",
		textColor = { red = 0.6, green = 0.6, blue = 0.6, alpha = 1 },
		textAlignment = "center",
		textSize = 14,
		frame = {
			x = 0,
			y = screenFrame.h - 40,
			w = screenFrame.w,
			h = 30,
		},
	})

	-- Mouse click handler
	canvas:canvasMouseEvents(true, true, false, false)
	canvas:mouseCallback(function(c, msg, id, x, y)
		if msg == "mouseUp" then
			-- Find which thumbnail was clicked
			for _, winInfo in ipairs(currentWindows) do
				local b = winInfo.bounds
				local localX = x + screenFrame.x
				local localY = y + screenFrame.y
				if localX >= b.x and localX <= b.x + b.w and
				   localY >= b.y and localY <= b.y + b.h + LABEL_HEIGHT then
					Expose.hide()
					Expose.selectWindow(winInfo.win)
					return
				end
			end
		end
	end)

	canvas:level(hs.canvas.windowLevels.modalPanel)
	canvas:show()
end

------------------------------------------
-- Keyboard Handling
------------------------------------------

local function startKeyWatcher()
	if keyWatcher then
		keyWatcher:stop()
	end

	keyWatcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		if not isVisible then
			return false
		end

		local keyCode = event:getKeyCode()
		local key = hs.keycodes.map[keyCode]
		local flags = event:getFlags()

		-- Escape or Cmd+Ctrl+Up to close
		if key == "escape" then
			Expose.hide()
			return true
		end

		-- Cmd+Ctrl+Up (keycode 126) to toggle closed
		if keyCode == 126 and flags.cmd and flags.ctrl and not flags.alt and not flags.shift then
			Expose.hide()
			return true
		end

		-- Check if it's a hint character
		if key and #key == 1 then
			local upperKey = key:upper()
			for _, winInfo in ipairs(currentWindows) do
				if winInfo.hint == upperKey then
					Expose.hide()
					Expose.selectWindow(winInfo.win)
					return true
				end
			end
		end

		-- Consume all other keys while expose is visible
		return true
	end)

	keyWatcher:start()
end

local function stopKeyWatcher()
	if keyWatcher then
		keyWatcher:stop()
		keyWatcher = nil
	end
end

------------------------------------------
-- Public API
------------------------------------------

function Expose.selectWindow(win)
	if not win then
		return
	end

	Windows.focusWindow(win, function()
		Windows.addToWindowStack(win)
		Tiling.bringIntoView(win)
		Windows.centerMouseInWindow(win)
	end)
end

function Expose.show()
	if isVisible then
		return
	end

	local currentScreen = hs.mouse.getCurrentScreen()
	if not currentScreen then
		print("[Expose] No current screen")
		return
	end

	local screenId = currentScreen:id()
	local spaceId = state.activeSpaceForScreen[screenId]

	if not state.screens[screenId] or not state.screens[screenId][spaceId] then
		print("[Expose] No windows in current space")
		return
	end

	-- Collect windows in current virtual space
	local windows = {}
	local space = state.screens[screenId][spaceId]

	-- Tiled windows
	for _, col in ipairs(space.cols or {}) do
		for _, winId in ipairs(col) do
			local win = Windows.getWindow(winId)
			if win then
				table.insert(windows, { winId = winId, win = win })
			end
		end
	end

	-- Floating windows
	if space.floating then
		for _, winId in ipairs(space.floating) do
			local win = Windows.getWindow(winId)
			if win then
				table.insert(windows, { winId = winId, win = win })
			end
		end
	end

	if #windows == 0 then
		print("[Expose] No windows to show")
		return
	end

	if #windows > #HINT_CHARS then
		print("[Expose] Too many windows, limiting to " .. #HINT_CHARS)
		local limited = {}
		for i = 1, #HINT_CHARS do
			limited[i] = windows[i]
		end
		windows = limited
	end

	print(string.format("[Expose] Showing %d windows", #windows))

	isVisible = true
	showCanvas(windows, currentScreen:frame())
	startKeyWatcher()
end

function Expose.hide()
	if not isVisible then
		return
	end

	isVisible = false
	stopKeyWatcher()

	if canvas then
		canvas:delete()
		canvas = nil
	end

	currentWindows = {}
end

function Expose.toggle()
	if isVisible then
		Expose.hide()
	else
		Expose.show()
	end
end

function Expose.init(wm)
	WM = wm
	state = wm.State.get()
	Windows = wm.Windows
	Tiling = wm.Tiling

	-- Start background snapshot caching
	startSnapshotTimer()

	-- Watch for window focus to mark windows as active and capture fresh snapshots
	Expose.focusWatcher = hs.window.filter.new():subscribe(
		hs.window.filter.windowFocused,
		function(win)
			if win then
				local winId = win:id()
				lastActiveTime[winId] = hs.timer.secondsSinceEpoch()
				-- Capture a fresh snapshot when window is focused (if it's in a visible space)
				local visibleIds = getVisibleWindowIds()
				if visibleIds[winId] then
					captureSnapshot(winId)
				end
			end
		end
	)

	print("[Expose] Module initialized with smart snapshot caching")
end

function Expose.stop()
	Expose.hide()
	stopSnapshotTimer()
	if Expose.focusWatcher then
		Expose.focusWatcher:unsubscribeAll()
		Expose.focusWatcher = nil
	end
	snapshotCache = {}
	lastActiveTime = {}
end

return Expose
