-- Urgency module: Manages window urgency tracking
local Urgency = {}
Urgency.__index = Urgency

-- Module dependencies
local Application <const> = hs.application
local Window <const> = hs.window

-- Local state reference (will be set during init)
local state = nil
local Windows = nil
local updateMenubar = nil
local updateCommandPalette = nil

------------------------------------------
-- Public API
------------------------------------------

-- Set or clear urgency for a window
function Urgency.setWindowUrgent(winId, urgent)
	if urgent then
		state.urgentWindows[winId] = true
		print("[urgency] Window " .. winId .. " marked urgent")
	else
		state.urgentWindows[winId] = nil
		print("[urgency] Window " .. winId .. " urgency cleared")
	end

	-- Update UI
	if updateMenubar then
		updateMenubar()
	end

	-- Refresh command palette if it's visible
	if updateCommandPalette then
		updateCommandPalette()
	end
end

-- Clear urgency for a window (convenience wrapper)
function Urgency.clearWindowUrgent(winId)
	Urgency.setWindowUrgent(winId, false)
end

-- Debug utility to list all urgent windows
function Urgency.debugUrgentWindows()
	print("=== Urgent Windows Debug ===")
	for winId, _ in pairs(state.urgentWindows) do
		local win = Windows.getWindow(winId)
		if win then
			print(string.format("  Window %d: %s (exists)", winId, win:title()))
		else
			print(string.format("  Window %d: (DEAD WINDOW)", winId))
		end
	end
	print("===========================")
end

-- Mark the currently focused window as urgent
function Urgency.setCurrentWindowUrgent()
	local win = Window.focusedWindow()
	if win then
		Urgency.setWindowUrgent(win:id(), true)
	end
end

-- Mark all windows of a specific app as urgent
function Urgency.setUrgentByApp(appName)
	local app = Application.get(appName)
	if not app then
		print("[urgency] Application not found: " .. appName)
		return
	end

	local count = 0
	for _, win in ipairs(app:allWindows()) do
		if win:isStandard() and win:isVisible() then
			Urgency.setWindowUrgent(win:id(), true)
			count = count + 1
		end
	end
	print("[urgency] Marked " .. count .. " windows urgent for app: " .. appName)
end

-- Clear all urgent window markers
function Urgency.clearAllUrgent()
	state.urgentWindows = {}
	print("[urgency] Cleared all urgent windows")
	if updateMenubar then
		updateMenubar()
	end
end

-- Check if there are any urgent windows
function Urgency.hasUrgentWindows()
	for _, _ in pairs(state.urgentWindows) do
		return true
	end
	return false
end

-- Initialize the urgency module
function Urgency.init(wm, stateRef, windowsModule, menubarCallback, commandPaletteCallback)
	Urgency.wm = wm
	state = stateRef
	Windows = windowsModule
	updateMenubar = menubarCallback
	updateCommandPalette = commandPaletteCallback
	print("[Urgency] Urgency module initialized")
end

return Urgency
