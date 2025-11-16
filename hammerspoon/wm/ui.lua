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
local commandPaletteMode = "root" -- "root", "moveWindowToSpace", "renameSpace", "createSpace"
local modeStack = {} -- Stack of previous modes for escape-to-go-back
local previousChoicesCount = 0

------------------------------------------
-- Private helpers
------------------------------------------

-- Fuzzy matching function for commands
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

	for textIdx = 1, textLen do
		if queryIdx > queryLen then
			break
		end

		local queryChar = lowerQuery:sub(queryIdx, queryIdx)
		local textChar = lowerText:sub(textIdx, textIdx)

		if queryChar == textChar then
			score = score + 100
			if queryIdx == 1 and textIdx == 1 then
				score = score + 200
			end
			if textIdx == lastMatchIdx + 1 then
				consecutiveMatches = consecutiveMatches + 1
				score = score + (50 * consecutiveMatches)
			else
				consecutiveMatches = 0
			end
			score = score + (100 - textIdx)
			lastMatchIdx = textIdx
			queryIdx = queryIdx + 1
		end
	end

	if queryIdx > queryLen then
		return score
	else
		return nil
	end
end

-- Build command palette choices based on current mode
local function buildCommandPaletteChoices(query)
	query = query or ""

	if commandPaletteMode == "root" then
		-- Root menu: show spaces and commands, all fuzzy searchable
		-- Get spaces without the create-on-no-match fallback
		local choices = Spaces.buildSpaceList(query, "switchSpace", false)

		-- Define commands
		local commands = {
			{
				text = "Move window to space",
				subText = "Move focused window to another space",
				actionType = "navigateToMoveWindow",
				valid = false,
			},
			{
				text = "Rename space",
				subText = "Rename the current space",
				actionType = "navigateToRenameSpace",
				valid = false,
			},
			{
				text = "Create space",
				subText = "Create a new named space",
				actionType = "navigateToCreateSpace",
				valid = false,
			},
		}

		-- Apply fuzzy filtering to commands
		if query ~= "" then
			for _, cmd in ipairs(commands) do
				local textScore = fuzzyMatch(query, cmd.text)
				local subTextScore = fuzzyMatch(query, cmd.subText)
				local bestScore = nil
				if textScore and subTextScore then
					bestScore = math.max(textScore, subTextScore)
				elseif textScore then
					bestScore = textScore
				elseif subTextScore then
					bestScore = subTextScore
				end
				if bestScore then
					cmd.score = bestScore
					table.insert(choices, cmd)
				end
			end
		else
			-- No query: add all commands with zero score
			for _, cmd in ipairs(commands) do
				cmd.score = 0
				table.insert(choices, cmd)
			end
		end

		-- Sort all choices by score (spaces already have scores from buildSpaceList)
		table.sort(choices, function(a, b)
			local aScore = a.score or 0
			local bScore = b.score or 0
			if aScore ~= bScore then
				return aScore > bScore
			end
			-- Commands come after spaces when scores are equal
			local aIsCommand = a.actionType and a.actionType:find("^navigate") ~= nil
			local bIsCommand = b.actionType and b.actionType:find("^navigate") ~= nil
			if aIsCommand ~= bIsCommand then
				return bIsCommand
			end
			return false
		end)

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
			table.insert(choices, {
				text = "Rename '" .. tostring(currentSpaceId) .. "' to '" .. query .. "'",
				subText = "Press enter to confirm",
				actionType = "renameSpace",
				newSpaceId = query,
				oldSpaceId = currentSpaceId,
				screenId = currentScreenId,
			})
		else
			table.insert(choices, {
				text = "Type new name for space '" .. tostring(currentSpaceId) .. "'",
				subText = "Current space will be renamed",
				actionType = "instruction",
				valid = false,
			})
		end

		return choices
	elseif commandPaletteMode == "createSpace" then
		local currentScreen = Mouse.getCurrentScreen()
		local currentScreenId = currentScreen:id()

		local choices = {}
		if query ~= "" then
			table.insert(choices, {
				text = "Create space '" .. query .. "'",
				subText = "Create new named space and switch to it",
				actionType = "createAndSwitchSpace",
				screenId = currentScreenId,
				spaceId = query,
			})
		else
			table.insert(choices, {
				text = "Type name for new space",
				subText = "New space will be created and activated",
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
		-- For named spaces, show full name
		local displayText
		if type(spaceId) == "string" then
			displayText = spaceId
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

-- Stop/cleanup UI resources
function UI.stop()
	if UI._menubar then
		print("[UI] Removing menubar")
		UI._menubar:delete()
		UI._menubar = nil
	end
	if UI.commandPalette then
		print("[UI] Removing command palette")
		UI.commandPalette:delete()
		UI.commandPalette = nil
	end
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
			-- Escape pressed: go back if in submenu, close if at root
			if #modeStack > 0 then
				commandPaletteMode = table.remove(modeStack)
				UI.commandPalette:query("")
				UI.commandPalette:choices(buildCommandPaletteChoices())
				UI.commandPalette:show()
				return
			end
			-- At root, close normally
			commandPaletteMode = "root"
			modeStack = {}
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
		modeStack = {}
	end)

	UI.commandPalette:invalidCallback(function(choice)
		if not choice then
			return
		end

		local actionType = choice.actionType
		if actionType == "navigateToMoveWindow" then
			print("[commandPalette] Navigating to moveWindowToSpace mode")
			table.insert(modeStack, commandPaletteMode)
			commandPaletteMode = "moveWindowToSpace"
			UI.commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			UI.commandPalette:choices(choices)
		elseif actionType == "navigateToRenameSpace" then
			print("[commandPalette] Navigating to renameSpace mode")
			table.insert(modeStack, commandPaletteMode)
			commandPaletteMode = "renameSpace"
			UI.commandPalette:query("")
			local choices = buildCommandPaletteChoices()
			UI.commandPalette:choices(choices)
		elseif actionType == "navigateToCreateSpace" then
			print("[commandPalette] Navigating to createSpace mode")
			table.insert(modeStack, commandPaletteMode)
			commandPaletteMode = "createSpace"
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
