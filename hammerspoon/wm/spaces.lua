local Spaces = {}

-- Dependencies
local State
local Windows

-- Hammerspoon imports
local Screen <const> = hs.screen
local Mouse <const> = hs.mouse

-- Get state reference
local state

------------------------------------------
-- Space lookup utilities
------------------------------------------

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

------------------------------------------
-- Space list building
------------------------------------------

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
			if choice.actionType == "createAndSwitchSpace" or choice.actionType == "createAndMoveWindowToSpace" then
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

------------------------------------------
-- Public API
------------------------------------------

function Spaces.init(wm)
	-- Get references to dependencies
	State = wm.State
	Windows = wm.Windows

	-- Get state reference
	state = State.get()

	print("[Spaces] Initialized")
end

function Spaces.getSpaceForWindow(winId)
	return getSpaceForWindow(winId)
end

function Spaces.getSpaceMRUOrder()
	return getSpaceMRUOrder()
end

function Spaces.getUrgentWindowsInSpace(screenId, spaceId)
	return getUrgentWindowsInSpace(screenId, spaceId)
end

function Spaces.isSpaceUrgent(screenId, spaceId)
	return isSpaceUrgent(screenId, spaceId)
end

function Spaces.buildSpaceList(query, actionType)
	return buildSpaceList(query, actionType)
end

return Spaces
