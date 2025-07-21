local WM      = {}
WM.__index    = WM

local serpent = dofile(hs.configdir .. "/serpent.lua")

-- Metadata
WM.name       = "WM"
WM.version    = "0.1"
WM.author     = "Thomas Millar"
WM.homepage   = "https://github.com/thmslmr/omaccy"
WM.license    = "MIT - https://opensource.org/licenses/MIT"

WM.log        = hs.logger.new(WM.name)
WM.log.setLogLevel('debug')

WM.tileGap     = 10
WM.resizeStep  = 200
WM.scrollSpeed = 400


local Application <const> = hs.application
local Axuielement <const> = hs.axuielement
local Event <const>       = hs.eventtap.event
local EventTypes <const>  = hs.eventtap.event.types
local Geometry <const>    = hs.geometry
local Mouse <const>       = hs.mouse
local Screen <const>      = hs.screen
local Spaces <const>      = hs.spaces
local Timer <const>       = hs.timer
local Window <const>      = hs.window
local Settings <const>    = hs.settings
local FnUtils <const>     = hs.fnutils
local json <const>        = hs.json


local _windows = {}
local state = {
    screens = {},
    activeSpaceForScreen = {},
    windowStack = {},
    windowStackIndex = 1,
    startXForScreenAndSpace = {},
    fullscreenOriginalWidth = {},
}

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
- [ ] Retile should manage z-index of windows across columns and rows using getOrderedWindows()
- [ ] When a screen is removed, all spaces on that screen should be moved to the rightmost screen


]] --


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
    if _windows[winId] then return _windows[winId] end
    _windows[winId] = Window(winId)
    return _windows[winId]
end

local function focusWindow(w, callback, opts)
    local skipStack = opts and opts.skipStack or false
    if not skipStack then WM._windowWatcherPaused = true end

    local function waitForFocus(attempts)
        if attempts == 0 then return end

        if Window.focusedWindow() ~= w then
            w:application():activate(true)
            Timer.doAfter(0.001, function()
                w:focus()
                Timer.doAfter(0.001, function()
                    waitForFocus(attempts - 1)
                end)
            end)
        else
            if not skipStack then
                WM._windowWatcherPaused = false
                addToWindowStack(w)
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
                if foundScreenId then break end
            end
            if foundScreenId then break end
        end
        if foundScreenId then break end
    end

    return foundScreenId, foundSpaceId, foundColIdx, foundRowIdx
end

local function retile(state, screenId, spaceId)
    local focusedWindowId = Window.focusedWindow():id()
    local cols = state.screens[screenId][spaceId].cols
    local screen = Screen(screenId)
    if not cols or #cols == 0 then return end

    local screenFrame = screen:frame()
    local y = screenFrame.y
    local h = screenFrame.h
    local x = state.startXForScreenAndSpace[screenId][spaceId]

    for _, col in ipairs(cols) do
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

        local colX = x
        local rowY = y
        for idx, winId in ipairs(col) do
            local win = getWindow(winId)
            if win then
                local frame = win:frame()
                local minX = screenFrame.x
                local maxX = screenFrame.x + screenFrame.w - maxColWidth
                local clampedX = math.min(math.max(colX, minX), maxX)
                frame.x = clampedX
                frame.y = rowY
                frame.w = maxColWidth

                -- Distribute remainder pixels to the first windows
                local extra = (idx <= remainder) and 1 or 0
                local winHeight = baseHeight + extra
                frame.h = winHeight

                win:setFrame(frame, 0)
                rowY = rowY + winHeight + WM.tileGap
            end
        end
        x = x + maxColWidth + WM.tileGap
    end
end

local function bringIntoView(win)
    if not win then return end
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

    if currentLeft < 0 then
        state.startXForScreenAndSpace[screenId][spaceId] = -preWidth
        retile(state, screenId, spaceId)
    elseif currentRight > screenFrame.w then
        state.startXForScreenAndSpace[screenId][spaceId] = -preWidth + screenFrame.w - win:frame().w
        retile(state, screenId, spaceId)
    else
        state.startXForScreenAndSpace[screenId][spaceId] = -preWidth + currentLeft
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
    if not win then return end
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
local function moveSpaceWindowsOffscreen(screenId, spaceId)
    if not state.screens[screenId] or not state.screens[screenId][spaceId] then return end

    local rightmostScreen = getRightmostScreen()
    local rightFrame = rightmostScreen:frame()
    local offscreenX = rightFrame.x + rightFrame.w - 1 -- leave 1px visible so macOS doesn't move it

    -- Move tiled windows
    for _, col in ipairs(state.screens[screenId][spaceId].cols) do
        for _, winId in ipairs(col) do
            local win = getWindow(winId)
            if win and win:isStandard() and win:isVisible() then
                local f = win:frame()
                f.x = offscreenX
                win:setFrame(f, 0)
            end
        end
    end

    -- Move floating windows if any
    if state.screens[screenId][spaceId].floating then
        for _, winId in ipairs(state.screens[screenId][spaceId].floating) do
            local win = getWindow(winId)
            if win and win:isStandard() and win:isVisible() then
                local f = win:frame()
                f.x = offscreenX
                win:setFrame(f, 0)
            end
        end
    end
end

local function retileAll()
    for screenId, spaces in pairs(state.screens) do
        for spaceId, _ in pairs(spaces) do
            if state.activeSpaceForScreen[screenId] == spaceId then
                retile(state, screenId, spaceId)
            else
                moveSpaceWindowsOffscreen(screenId, spaceId)
            end
        end
    end
end

local function getWindowStackIndex(winId)
    for i, v in ipairs(state.windowStack) do
        if v == winId then
            return i
        end
    end
end

addToWindowStack = function(win)
    if not win or not win:id() then return end
    local id = win:id()
    if state.windowStackIndex and state.windowStackIndex > 1 then
        for i = state.windowStackIndex - 1, 1, -1 do
            table.remove(state.windowStack, i)
        end
        state.windowStackIndex = 1
    end
    local idx = getWindowStackIndex(id)
    if idx then table.remove(state.windowStack, idx) end
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
WM._windowWatcher = hs.window.filter.new():subscribe(
    hs.window.filter.windowFocused,
    function(win, appName, event)
        if windowWatcherPaused then return end
        print("[windowFocused]", win:title(), win:id(), windowWatcherPaused)
        addToWindowStack(win)
        local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
        if not screenId or not spaceId or not colIdx or not rowIdx then return end
        if state.activeSpaceForScreen[screenId] ~= spaceId then
            state.activeSpaceForScreen[screenId] = spaceId
            retileAll()
        end
    end
)

-- Subscribe to window created/destroyed events to update state

WM._windowWatcher:subscribe(
    hs.window.filter.windowCreated,
    function(win, appName, event)
        if windowWatcherPaused then return end
        if not win:isStandard() or not win:isVisible() or win:isFullScreen() then return end
        print("[windowCreated]", win:title(), win:id())

        -- If the window is already on a screen, don't do anything
        local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
        if screenId ~= nil then return end

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
        -- retile(state, screenId, spaceId)
        retileAll()
    end
)

WM._windowWatcher:subscribe(
    hs.window.filter.windowDestroyed,
    function(win, appName, event)
        if windowWatcherPaused then return end
        print("[windowDestroyed]", win:title(), win:id())

        local winId = win:id()
        local screenId, spaceId, colIdx, rowIdx = locateWindow(winId)
        if not screenId or not spaceId or not colIdx or not rowIdx then return end
        local col = state.screens[screenId][spaceId].cols[colIdx]
        if not col then return end
        for i = #col, 1, -1 do
            if col[i] == winId then
                table.remove(col, i)
                break
            end
        end
        if #col == 0 then
            table.remove(state.screens[screenId][spaceId].cols, colIdx)
        end

        -- Remove from windowStack
        for i = #state.windowStack, 1, -1 do
            if state.windowStack[i] == winId then
                table.remove(state.windowStack, i)
            end
        end
        -- Adjust windowStackIndex if needed
        if state.windowStackIndex > #state.windowStack then
            state.windowStackIndex = #state.windowStack
        end
        if state.windowStackIndex < 1 then
            state.windowStackIndex = 1
        end

        -- Remove from fullscreenOriginalWidth
        state.fullscreenOriginalWidth[winId] = nil

        -- Retile all screens/spaces (could optimize to just affected ones)
        retileAll()
    end
)

WM._windowWatcher:subscribe(
    { hs.window.filter.windowFullscreened, hs.window.filter.windowUnfullscreened },
    function(win, appName, event)
        if windowWatcherPaused then return end
        retileAll()
    end
)

function WM:navigateStack(direction)
    if direction == "in" then state.windowStackIndex = state.windowStackIndex - 1 end
    if direction == "out" then state.windowStackIndex = state.windowStackIndex + 1 end
    if state.windowStackIndex < 1 then state.windowStackIndex = 1 end
    if state.windowStackIndex > #state.windowStack then state.windowStackIndex = #state.windowStack end
    local winId = state.windowStack[state.windowStackIndex]
    if not winId then return end
    local win = getWindow(winId)
    if not win then return end

    -- print("--- Navigate window stack ---")
    -- for i, id in ipairs(state.windowStack) do
    --     local w = getWindow(id)
    --     local title = w and w:title() or tostring(id)
    --     local marker = (i == state.windowStackIndex) and ">" or " "
    --     print(string.format("%s [%d] %s", marker, i, title))
    -- end

    local screenId, spaceId, _, _ = locateWindow(winId)
    if not screenId or not spaceId then return end
    local currentSpaceId = state.activeSpaceForScreen[screenId]
    if spaceId ~= currentSpaceId then
        state.activeSpaceForScreen[screenId] = spaceId
        retileAll()
    end

    windowWatcherPaused = true
    focusWindow(win, function()
        bringIntoView(win)
        centerMouseInWindow(win)
        hs.timer.doAfter(0.1, function()
            windowWatcherPaused = false
        end)
    end, { skipStack = true })
end

function WM:focusDirection(direction)
    local currentScreenId, currentSpace, currentColIdx, currentRowIdx = locateWindow(Window.focusedWindow():id())

    if not currentColIdx then return end
    if direction == "left" then
        currentColIdx = currentColIdx - 1
        if currentColIdx < 1 then return end
        currentRowIdx = earliestIndexInList(state.screens[currentScreenId][currentSpace].cols[currentColIdx],
            state.windowStack) or 1
    end
    if direction == "right" then
        currentColIdx = currentColIdx + 1
        if currentColIdx > #state.screens[currentScreenId][currentSpace].cols then return end
        currentRowIdx = earliestIndexInList(state.screens[currentScreenId][currentSpace].cols[currentColIdx],
            state.windowStack) or 1
    end

    if direction == "down" then currentRowIdx = currentRowIdx + 1 end
    if direction == "up" then currentRowIdx = currentRowIdx - 1 end
    if currentRowIdx < 1 then return end
    if currentRowIdx > #state.screens[currentScreenId][currentSpace].cols[currentColIdx] then return end

    local nextWindow = getWindow(state.screens[currentScreenId][currentSpace].cols[currentColIdx][currentRowIdx])
    retileAll()
    if nextWindow then
        focusWindow(nextWindow, function()
            bringIntoView(nextWindow)
            centerMouseInWindow(nextWindow)
        end)
    end
end

function WM:moveDirection(direction)
    local currentScreenId, currentSpace, currentColIdx, _ = locateWindow(Window.focusedWindow():id())
    local nextColIdx = nil

    if not currentColIdx then return end
    if direction == "left" then nextColIdx = currentColIdx - 1 end
    if direction == "right" then nextColIdx = currentColIdx + 1 end
    if not nextColIdx then return end
    if nextColIdx < 1 then return end
    if nextColIdx > #state.screens[currentScreenId][currentSpace].cols then return end

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
    if not win then return end

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

    local screenId = win:screen():id()
    local spaceId = state.activeSpaceForScreen[screenId]
    retile(state, screenId, spaceId)
end

function WM:centerWindow()
    local win = Window.focusedWindow()
    if not win then return end
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
    if not win then return end
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

    retile(state, screenId, spaceId)
end

function WM:resizeFocusedWindowVertically(delta)
    local win = Window.focusedWindow()
    if not win or delta == 0 then return end

    local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
    if not (screenId and spaceId and colIdx and rowIdx) then return end

    local col = state.screens[screenId][spaceId].cols[colIdx]
    if not col or #col < 2 then return end

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
    local focusNew = math.max(minHeight,
        math.min(focusCurrent + delta,
            totalColHeight - minHeight * (n - 1)))
    if focusNew == focusCurrent then return end

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
                if leftover == 0 then break end
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
        w:setFrame(f, 0)
        y = y + f.h + WM.tileGap
    end
end

function WM:switchToSpace(spaceId)
    windowWatcherPaused = true

    local currentScreen = Mouse.getCurrentScreen()
    local screenId = currentScreen:id()

    local currentSpace = state.activeSpaceForScreen[screenId]
    if currentSpace == spaceId then return end

    moveSpaceWindowsOffscreen(screenId, currentSpace)
    state.activeSpaceForScreen[screenId] = spaceId
    retile(state, screenId, spaceId)

    local candidateWindowIds = flatten(state.screens[screenId][spaceId].cols)
    local nextWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
    local nextWindowId = candidateWindowIds[nextWindowIdx] or candidateWindowIds[1]
    if nextWindowId then
        local nextWindow = getWindow(nextWindowId)
        focusWindow(nextWindow, function()
            bringIntoView(nextWindow)
            centerMouseInWindow(nextWindow)
            windowWatcherPaused = false
        end)
    else
        windowWatcherPaused = false
    end
end

function WM:slurp()
    local win = Window.focusedWindow()
    if not win then return end
    local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
    if not screenId or not spaceId or not colIdx or not rowIdx then return end
    local cols = state.screens[screenId][spaceId].cols
    if colIdx >= #cols then return end -- No column to the right
    local rightCol = cols[colIdx + 1]
    if not rightCol or #rightCol == 0 then return end

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
                w:setFrame(f, 0)
                y = y + winHeight + WM.tileGap
            end
        end
    end

    retile(state, screenId, spaceId)
end

function WM:barf()
    local win = Window.focusedWindow()
    if not win then return end
    local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
    if not screenId or not spaceId or not colIdx or not rowIdx then return end
    local cols = state.screens[screenId][spaceId].cols
    if #cols == 0 then return end
    if colIdx == #cols then cols[colIdx + 1] = {} end
    if #cols[colIdx] == 0 then return end
    if #cols[colIdx] == 1 then return end
    local removedWin = table.remove(cols[colIdx], #cols[colIdx])
    if not removedWin then return end
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
                        w:setFrame(f, 0)
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
    if not win then return end

    local screenId, currentSpace, colIdx, rowIdx = locateWindow(win:id())
    if not screenId or not currentSpace or not colIdx or not rowIdx then return end
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
    local screenId, spaceId, colIdx, rowIdx = locateWindow(win:id())
    if not win then return end
    win:close()
    if not screenId or not spaceId or not colIdx or not rowIdx then return end
    if colIdx > 1 then colIdx = colIdx - 1 end
    local nextWindowId = state.screens[screenId][spaceId].cols[colIdx][1]
    local nextWindow = getWindow(nextWindowId)
    nextWindow:focus()
    centerMouseInWindow(nextWindow)
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
            local screenId, spaceId, _, _ = locateWindow(nextWindowId)
            if not screenId or not spaceId then return end
            local currentSpaceId = state.activeSpaceForScreen[screenId]
            if spaceId ~= currentSpaceId then
                state.activeSpaceForScreen[screenId] = spaceId
                retileAll()
            end
            local nextWindow = getWindow(nextWindowId)
            focusWindow(nextWindow, function()
                bringIntoView(nextWindow)
                centerMouseInWindow(nextWindow)
            end)
            return
        end
    end

    local targetScreen = Mouse.getCurrentScreen()
    local targetScreenId = targetScreen:id()
    local targetSpaceId = state.activeSpaceForScreen[targetScreenId]

    local candidateWindowIds = flatten(state.screens[targetScreenId][targetSpaceId].cols)
    local earliestWindowIdx = earliestIndexInList(candidateWindowIds, state.windowStack)
    if earliestWindowIdx == nil then earliestWindowIdx = 1 end
    local targetColIdx
    if #candidateWindowIds > 0 then
        _, _, targetColIdx, _ = locateWindow(candidateWindowIds[earliestWindowIdx])
        if targetColIdx ~= nil then targetColIdx = targetColIdx + 1 end
        if targetColIdx == nil then targetColIdx = 1 end
    else
        targetColIdx = 1
    end

    local windowsBefore = {}
    for _, win in ipairs(Window.allWindows()) do windowsBefore[win:id()] = win end

    local function waitForNewWindow(attempts, callback)
        if attempts <= 0 then
            return
        end
        local windowsAfter = {}
        for _, win in ipairs(Window.allWindows()) do windowsAfter[win:id()] = win end
        for winId, win in pairs(windowsAfter) do
            if not windowsBefore[winId] then
                callback(win)
                return
            end
        end
        hs.timer.doAfter(0.025, function() waitForNewWindow(attempts - 1, callback) end)
    end

    local function waitAndHandleNewWindow()
        waitForNewWindow(10, function(newWindow)
            table.insert(state.screens[targetScreenId][targetSpaceId].cols, targetColIdx, { newWindow:id() })
            retile(state, targetScreenId, targetSpaceId)
            focusWindow(newWindow, function()
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
                    screenId                                              = placed.screenId
                    spaceId                                               = placed.spaceId
                    colIdx                                                = placed.colIdx
                    rowIdx                                                = placed.rowIdx
                    state.screens[screenId][spaceId].cols[colIdx]         = state.screens[screenId][spaceId].cols
                        [colIdx] or {}
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

    for screenId, spaces in pairs(state.screens) do
        for spaceId, space in pairs(spaces) do
            if state.activeSpaceForScreen[screenId] == spaceId then
                retile(state, screenId, spaceId)
            else
                moveSpaceWindowsOffscreen(screenId, spaceId)
            end
        end
    end

    addToWindowStack(Window.focusedWindow())
end

hs.hotkey.bind({ "cmd", "ctrl" }, "t", function()
    print(hs.inspect(state.screens))
end)

return WM
