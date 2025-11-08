# Window Manager Refactoring Plan

## Goal
Refactor the 2,735-line `wm.lua` into 8 focused modules following the PaperWM.spoon architecture pattern.

## Target Module Structure

```
hammerspoon/
├── wm.lua              # Main module (init/coordination) ~200 lines
├── wm/
│   ├── state.lua       # State management & persistence (~250 lines)
│   ├── windows.lua     # Window utilities & operations (~300 lines)
│   ├── tiling.lua      # Retiling engine & layout (~400 lines)
│   ├── spaces.lua      # Space management & navigation (~350 lines)
│   ├── actions.lua     # Public action methods (~600 lines)
│   ├── events.lua      # Event handlers & watchers (~250 lines)
│   ├── ui.lua          # Command palette & menubar (~500 lines)
│   └── urgency.lua     # Urgency tracking system (~150 lines)
```

## Module Responsibilities

### state.lua
- State schema definition
- Persistence (saveState/loadState)
- State cleaning utilities
- Migration logic for disconnected screens
- No dependencies on other modules

### windows.lua
- Window caching (`getWindow()`, `_windows` cache)
- Window validation (`isValidWindow()`)
- Window location (`locateWindow()`)
- Window focusing (`focusWindow()` with retry logic)
- Geometry utilities (`framesDiffer()`)
- Window stack operations (`cleanWindowStack()`, `addToWindowStack()`)
- Z-order management (`updateZOrder()`)
- Mouse utilities (`centerMouseInWindow()`)
- Dependencies: `state`

### tiling.lua
- Core `retile()` function
- `retileAll()` orchestration
- `bringIntoView()` scrolling logic
- Offscreen window management (`moveSpaceWindowsOffscreen()`)
- Screen utilities (`getRightmostScreen()`)
- Clipping calculations
- Dependencies: `state`, `windows`

### spaces.lua
- Space lookup utilities (`getSpaceForWindow()`)
- MRU order tracking (`getSpaceMRUOrder()`)
- Urgency checking (`isSpaceUrgent()`, `getUrgentWindowsInSpace()`)
- Space list building (for command palette)
- Fuzzy matching for spaces
- Dependencies: `state`, `windows`

### actions.lua
- Navigation: `focusDirection()`, `navigateStack()`, `nextScreen()`
- Manipulation: `moveDirection()`, `slurp()`, `barf()`
- Space ops: `switchToSpace()`, `createSpace()`, `renameSpace()`
- Window ops: `toggleFullscreen()`, `resize*()`, `centerWindow()`
- App launching: `launchOrFocusApp()`
- Scroll: `scroll()`
- Dependencies: `state`, `windows`, `tiling`, `spaces`, `urgency`

### events.lua
- Window watcher setup
- Focus tracking
- Window creation/destruction handlers
- Watcher pause/resume logic
- Dependencies: `state`, `windows`, `tiling`, `actions`

### ui.lua
- Command palette implementation
- Menubar indicator
- Choice building (`buildCommandPaletteChoices()`)
- Mode management (root/moveWindow/rename)
- Dependencies: `state`, `spaces`, `actions`, `urgency`

### urgency.lua
- `setWindowUrgent()`, `clearWindowUrgent()`
- `setCurrentWindowUrgent()`, `setUrgentByApp()`
- `clearAllUrgent()`, `debugUrgentWindows()`
- Urgency state management
- Dependencies: `state`, `windows`

## Incremental Refactoring Phases

### Phase 1: Extract State Module ✅
- [x] Create `wm/state.lua`
- [x] Move state schema definition
- [x] Move persistence functions (loadSavedState, saveState)
- [x] Move state cleaning utilities (cleanSavedStateWindows)
- [x] Move migration logic (migrateDisconnectedScreens)
- [x] Move initialization helpers (initializeScreenStructures, reconcileWindows, getCurrentWindows)
- [x] Add State.init(), State.save(), State.load() public API
- [x] Update wm.lua to use State module
- [x] Test: Reload preserves state exactly as before
- [x] Test: All window positions preserved across reload
- [x] Test: Space switching works correctly
- [x] Test: Window stack navigation works

### Phase 2: Extract Windows Utilities ✅
- [x] Create `wm/windows.lua`
- [x] Move window caching (`getWindow()`, `_windows`)
- [x] Move window validation (used in cleanWindowStack)
- [x] Move window location (`locateWindow()`)
- [x] Move window focusing (`focusWindow()`)
- [x] Move window stack operations (`cleanWindowStack()`, `addToWindowStack()`, `getWindowStackIndex()`)
- [x] Move z-order management (`updateZOrder()`)
- [x] Move geometry utilities (`framesDiffer()`)
- [x] Move mouse utilities (`centerMouseInWindow()`)
- [x] Move helper utilities (`flatten()`, `earliestIndexInList()`)
- [x] Update wm.lua to use Windows module via convenience aliases
- [x] Test: Window focusing works with retry logic
- [x] Test: Window stack navigation preserves order
- [x] Test: State persistence across reloads

### Phase 3: Extract Tiling Engine ✅
- [x] Create `wm/tiling.lua`
- [x] Move `retile()` function
- [x] Move `retileAll()` orchestration
- [x] Move `bringIntoView()` scrolling logic
- [x] Move offscreen management (`moveSpaceWindowsOffscreen()`)
- [x] Move screen utilities (`getRightmostScreen()`)
- [x] Update wm.lua to use Tiling module
- [x] Test: Tiling preserves layout correctly
- [x] Test: Scrolling brings windows into view
- [x] Test: Space switching moves windows offscreen
- [x] Test: Multi-monitor support works

### Phase 4: Extract Spaces Module ✅
- [x] Create `wm/spaces.lua`
- [x] Move space lookup (`getSpaceForWindow()`)
- [x] Move MRU tracking (`getSpaceMRUOrder()`)
- [x] Move space list building (`buildSpaceList()`)
- [x] Move fuzzy matching logic
- [x] Move urgency space helpers (`isSpaceUrgent()`, `getUrgentWindowsInSpace()`)
- [x] Update wm.lua to use Spaces module
- [x] Test: Space switching works correctly
- [x] Test: Command palette space filtering works
- [x] Test: Fuzzy matching finds correct spaces
- [x] Test: MRU order is correct

### Phase 5: Extract Urgency Module ✅
- [x] Create `wm/urgency.lua`
- [x] Move urgency state management
- [x] Move `setWindowUrgent()`, `clearWindowUrgent()`
- [x] Move `setCurrentWindowUrgent()`, `setUrgentByApp()`
- [x] Move `clearAllUrgent()`, `debugUrgentWindows()`
- [x] Add `hasUrgentWindows()` helper function
- [x] Update wm.lua to use Urgency module
- [x] Test: Urgency indicators show correctly
- [x] Test: Clearing urgency on focus works
- [x] Test: Menubar updates with urgency

### Phase 6: Extract UI Module ✅
- [x] Create `wm/ui.lua`
- [x] Move command palette implementation (`setupUI()` portions)
- [x] Move menubar implementation (`updateMenubar()`)
- [x] Move choice building (`buildCommandPaletteChoices()`)
- [x] Move mode management (commandPaletteMode state)
- [x] Update wm.lua to use UI module
- [x] Fix initialization order (UI before Urgency, menubar after Urgency)
- [x] Test: Command palette opens and closes
- [x] Test: Space creation from palette works
- [x] Test: Window moving from palette works
- [x] Test: Space renaming from palette works
- [x] Test: Menubar updates correctly

### Phase 7: Extract Events & Actions
- [ ] Create `wm/events.lua`
- [ ] Move window watcher setup
- [ ] Move focus tracking
- [ ] Move window creation/destruction handlers
- [ ] Move watcher pause/resume logic
- [ ] Create `wm/actions.lua`
- [ ] Move all public `WM:*` methods
- [ ] Slim down main `wm.lua` to coordination only
- [ ] Update wm.lua to delegate to Actions module
- [ ] Test: All hotkeys work
- [ ] Test: Window creation triggers retile
- [ ] Test: Window destruction cleans up state
- [ ] Test: Focus tracking updates stack
- [ ] Test: All public actions work end-to-end

## Testing Checklist (Per Phase)

After each phase, verify:
- [ ] Window manager reloads without errors
- [ ] All existing windows remain in correct positions
- [ ] Space switching works
- [ ] Window focusing works
- [ ] Window stack navigation works
- [ ] State persists across reload
- [ ] No console errors
- [ ] Hotkeys still function

## Success Criteria

- All 7 phases completed
- Each module is 150-600 lines
- Main wm.lua is ~200 lines
- All tests pass
- No regression in functionality
- Code is more maintainable and testable
