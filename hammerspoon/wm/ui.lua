-- UI module: Manages command palette and menubar
local UI = {}
UI.__index = UI

-- Module dependencies
local Mouse <const> = hs.mouse
local Screen <const> = hs.screen

-- Local state references (will be set during init)
local state = nil
local WM = nil
local Spaces = nil
local Urgency = nil
local Windows = nil

-- UI state
local commandPaletteMode = "root" -- "root", "moveWindowToSpace", "renameSpace"
local previousChoicesCount = 0

------------------------------------------
-- Private helpers
------------------------------------------

-- Build command palette choices based on current mode
local function buildCommandPaletteChoices(query)
	query = query or ""

	if commandPaletteMode == "root" then
		-- Root menu: show spaces directly for switching, plus additional commands
		local choices = Spaces.buildSpaceList(query, "switchSpace")

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
		local choices = Spaces.buildSpaceList(query, "moveWindowToSpace")
		return choices
	elseif commandPaletteMode == "renameSpace" then
		local currentScreen = Mouse.getCurrentScreen()
		local currentScreenId = currentScreen:id()
		local currentSpaceId = state.activeSpaceForScreen[currentScreenId]

		local choices = {}
		if query ~= "" then
			-- Show action to rename the space
			table.insert(choices, {
				text = "Rename '" .. tostring(currentSpaceId) .. "' to '" .. query .. "'",
				subText = "Press enter to confirm",
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

-- Helper to update command palette if visible
local function updateCommandPalette()
	if UI.commandPalette and UI.commandPalette:isVisible() then
		local currentQuery = UI.commandPalette:query()
		local choices = buildCommandPaletteChoices(currentQuery)
		UI.commandPalette:choices(choices)
	end
end

------------------------------------------
-- Public API
------------------------------------------

-- Update menubar indicator
function UI.updateMenubar()
	if not UI._menubar then
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
	if Urgency.hasUrgentWindows() then
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

	UI._menubar:setTitle(title)
	UI._menubar:setMenu(menu)
end

-- Show command palette
function UI.showCommandPalette()
	if not UI.commandPalette then
		return
	end

	-- Reset to root mode
	commandPaletteMode = "root"

	-- Clean window stack before building choices to ensure fresh MRU data
	Windows.cleanWindowStack()

	-- Refresh choices when showing
	local choices = buildCommandPaletteChoices()
	UI.commandPalette:choices(choices)
	previousChoicesCount = #choices
	UI.commandPalette:query("") -- Clear search text from previous invocation
	UI.commandPalette:show()
end

-- Get reference to updateCommandPalette for callbacks
function UI.getUpdateCommandPalette()
	return updateCommandPalette
end

-- Initialize the UI module
function UI.init(wm, stateRef, spacesModule, urgencyModule, windowsModule)
	WM = wm
	state = stateRef
	Spaces = spacesModule
	Urgency = urgencyModule
	Windows = windowsModule

	print("[UI] Initializing UI module")

	-- Create menubar space indicator (but don't update it yet - wait for Urgency module init)
	UI._menubar = hs.menubar.new()

	-- Create command palette (fuzzy finder for commands and spaces)
	UI.commandPalette = hs.chooser.new(function(choice)
		if not choice then
			commandPaletteMode = "root"
			UI.commandPalette:hide()
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

	UI.commandPalette:invalidCallback(function(choice)
		if not choice then
			return
		end

		local actionType = choice.actionType
		if actionType == "navigateToMoveWindow" then
			print("[commandPalette] Navigating to moveWindowToSpace mode")
			commandPaletteMode = "moveWindowToSpace"
			UI.commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			UI.commandPalette:choices(choices)
		elseif actionType == "navigateToRenameSpace" then
			print("[commandPalette] Navigating to renameSpace mode")
			commandPaletteMode = "renameSpace"
			UI.commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			UI.commandPalette:choices(choices)
		end
	end)

	UI.commandPalette:queryChangedCallback(function(query)
		local choices = buildCommandPaletteChoices(query)
		UI.commandPalette:choices(choices)

		-- Reset selection to first item if results changed
		if #choices ~= previousChoicesCount then
			UI.commandPalette:selectedRow(1)
			previousChoicesCount = #choices
		end
	end)

	UI.commandPalette:bgDark(true)

	print("[UI] UI module initialized")
end

return UI
