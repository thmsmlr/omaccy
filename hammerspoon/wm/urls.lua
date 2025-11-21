local URLs = {}

-- Dependencies (set during init)
local WM

-- Open URL in browser, preferring a window on the sender's space
local function openURLInBrowser(url, senderPID)
	local config = WM.browserConfig
	print(string.format("[URLs] Opening URL: %s", url))

	-- Determine which space to use based on sender window
	local targetScreenId, targetSpaceId
	if senderPID and senderPID > 0 then
		local app = hs.application.applicationForPID(senderPID)
		if app then
			local win = app:focusedWindow()
			if win then
				targetScreenId, targetSpaceId = WM.Spaces.getSpaceForWindow(win:id())
				print(string.format("[URLs] Sender window %d is on screen=%s space=%s",
					win:id(), tostring(targetScreenId), tostring(targetSpaceId)))
			end
		end
	end

	-- Fallback to active space if we couldn't determine from sender
	if not targetScreenId or not targetSpaceId then
		local state = WM.State.get()
		local screen = hs.screen.mainScreen()
		targetScreenId = screen:id()
		targetSpaceId = state.activeSpaceForScreen[targetScreenId]
		print(string.format("[URLs] Falling back to active space: screen=%s space=%s",
			tostring(targetScreenId), tostring(targetSpaceId)))
	end

	-- Try to find existing browser window on target space
	local browserWin = WM.Actions.findAppWindowOnSpace(config.bundleID, targetScreenId, targetSpaceId)

	if browserWin then
		local frame = browserWin:frame()
		local x, y = math.floor(frame.x), math.floor(frame.y)
		print(string.format("[URLs] Found browser window on space: id=%d pos=(%d,%d)", browserWin:id(), x, y))

		local script = config.openURLInWindowScript(x, y, url)
		local ok, result, raw = hs.osascript.applescript(script)
		print(string.format("[URLs] AppleScript result: ok=%s result=%s", tostring(ok), tostring(result)))
		if not ok then
			print(string.format("[URLs] AppleScript error: %s", tostring(raw)))
		end

		browserWin:focus()
	else
		print("[URLs] No browser window on current space, launching new window")

		WM.Actions.launchAppWindowOnSpace(config.bundleID, targetScreenId, targetSpaceId, {
			menuPath = config.menuNewWindow,
			onWindowReady = function(win)
				-- Navigate to URL after window is ready
				hs.timer.doAfter(0.1, function()
					local script = config.setURLScript(url)
					hs.osascript.applescript(script)
				end)
			end,
		})
	end
end

function URLs.init(wm)
	WM = wm

	-- Handle incoming URLs
	hs.urlevent.httpCallback = function(scheme, host, params, fullURL, senderPID)
		print(string.format("[URLs] httpCallback: fullURL=%s senderPID=%s", tostring(fullURL), tostring(senderPID)))
		openURLInBrowser(fullURL, senderPID)
	end

	print("[URLs] Registered URL handler")
end

return URLs
