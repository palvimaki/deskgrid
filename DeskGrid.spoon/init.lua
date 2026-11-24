local HOME = os.getenv("HOME")
local obj = {}
obj.__index = obj
obj.name = "DeskGrid"
obj.version = "4.2"
obj.author = "DeskGrid contributors"
obj.license = "MIT"
obj.homepage = "https://github.com/palvimaki/deskgrid"

obj.layoutsFile = os.getenv("HOME") .. "/.hammerspoon/deskgrid_layouts.json"
obj.configFile = os.getenv("HOME") .. "/.hammerspoon/deskgrid_config.json"
obj.hotkeys = {}
obj.menubar = nil
obj.stateRoot = os.getenv("HOME") .. "/.hammerspoon/deskgrid-state"
obj.sourceDirectory = debug.getinfo(1, "S").source:sub(2):match("^(.*)/")
obj._undo = nil
obj.activeRun = false
obj.captureTasks = {}
-- Running timers are retained here so that garbage collection cannot stop one
-- and leave a run without its final callback.
obj._timers = {}
-- Process start times by PID. One `ps` per PID per interval, instead of one
-- `ps` per identity check, keeps the Hammerspoon main thread responsive.
obj._identityCache = {}
obj.identityCacheSeconds = 30
-- A run that has not finished after this time is treated as stuck, so the
-- next hotkey press can start a new run without a Hammerspoon reload.
obj.runTimeoutSeconds = 45

obj.roleRules = {
  { role = "terminal", patterns = { "terminal", "iterm", "warp", "kitty", "alacritty", "wezterm" } },
  { role = "side", patterns = { "claude", "chatgpt", "codex", "linear", "jira", "things", "todoist", "trello", "notion", "notes", "obsidian" } },
  { role = "main", patterns = { "safari", "chrome", "firefox", "arc", "edge", "browser", "xcode", "code", "cursor", "zed", "sublime", "coteditor", "figma", "sketch" } },
  { role = "utility", patterns = { "finder", "slack", "discord", "telegram", "whatsapp", "teams", "zoom", "mail", "calendar", "preview" } },
}

obj.clutterPatterns = {
  "finder",
  "coteditor",
  "textedit",
  "preview",
}

obj.excludedBundles = {
  ["org.hammerspoon.Hammerspoon"] = true,
  ["com.apple.notificationcenterui"] = true,
  ["com.apple.systempreferences"] = true,
  ["com.apple.systemevents"] = true,
  ["com.apple.loginwindow"] = true,
}

obj.protectedBundles = {
  ["org.hammerspoon.Hammerspoon"] = true,
  ["com.obsproject.obs-studio"] = true,
}

obj.uncapturedBrowserBundles = {
  ["org.mozilla.firefox"] = true,
  ["company.thebrowser.Browser"] = true,
  ["com.microsoft.edgemac"] = true,
  ["com.brave.Browser"] = true,
  ["com.operasoftware.Opera"] = true,
  ["com.vivaldi.Vivaldi"] = true,
  ["com.kagi.kagimacOS"] = true,
  ["org.chromium.Chromium"] = true,
  ["com.google.Chrome.beta"] = true,
}

-- The live app minimum widths total 3874 pixels on the 3840-pixel development
-- display. Normalize them to the display so the unavoidable overlap is spread
-- as a small 4-8 pixel seam between adjacent columns.
obj.defaultFractions = { 573 / 3874, 883 / 3874, 574 / 3874, 473 / 3874, 500 / 3874, 871 / 3874 }

function obj:start()
  self:_ensureStateFiles()
  if self.dragSwap then self.dragSwap:stop() end
  self.dragSwap = dofile(self.sourceDirectory .. "/drag-swap.lua").new(self)
  self.dragSwap:start()
  self:_setupMenu()
  print("[DeskGrid] started v" .. self.version)
end

function obj:bindHotkeys(mapping)
  if mapping.default then
    self.hotkeys.default = hs.hotkey.bind(mapping.default[1], mapping.default[2], function()
      self:applyDefault()
    end)
  end
  if mapping.smart then
    self.hotkeys.smart = hs.hotkey.bind(mapping.smart[1], mapping.smart[2], function()
      self:applySmartStart()
    end)
  end
  if mapping.save then
    self.hotkeys.save = hs.hotkey.bind(mapping.save[1], mapping.save[2], function()
      self:saveCurrent()
    end)
  end
  if mapping.list then
    self.hotkeys.list = hs.hotkey.bind(mapping.list[1], mapping.list[2], function()
      self:listAndPick()
    end)
  end
  if mapping.setup then
    self.hotkeys.setup = hs.hotkey.bind(mapping.setup[1], mapping.setup[2], function()
      self:firstLaunch()
    end)
  end
  if mapping.closeMinimized then
    self.hotkeys.closeMinimized = hs.hotkey.bind(mapping.closeMinimized[1], mapping.closeMinimized[2], function()
      self:closeMinimizedWindows()
    end)
  end
end

function obj:firstLaunch()
  hs.dialog.blockAlert("DeskGrid", self:_shortcutText(), "OK", nil, "informational")
end

function obj:applyDefault()
  -- Honor the user's configured saved desk, including newly approved defaults.
  local config, layouts = self:_loadConfig(), self:_loadLayouts()
  if config.error or layouts.error then self:_toast(config.error or layouts.error); return end
  local name = config.defaultLayout
  local saved = type(name) == "string" and layouts.layouts[name] or nil
  if name == "smart" then self:applySmartStart(); return end
  if type(saved) == "table" and saved.kind == "snapshot" then
    self:_applyLayout(name)
    return
  end
  -- The fixed app grid runs only when chosen; anything else uses smart.
  if name ~= "development" then self:applySmartStart(); return end
  if not self:_claimRun() then return end
  self:_runFactory(function() return self:_createDefaultPlan() end)
end

function obj:applySmartStart()
  if not self:_claimRun() then return end
  self:_runFactory(function() return self:_createSmartPlan() end)
end

function obj:saveCurrent()
  if self._saving then self:_toast("A save is already in progress"); return end
  local button, text = hs.dialog.textPrompt("Save Layout", "Name this desk:", "", "Save", "Cancel")
  if button ~= "Save" or not text or text == "" then
    return
  end

  local layoutName = self:_slug(text)
  if layoutName == "" then self:_toast("Enter a layout name"); return end
  local existing = self:_loadLayouts()
  if existing.error then self:_toast(existing.error); return end
  local prior = existing.layouts[layoutName]
  if prior ~= nil then
    local label = type(prior) == "table" and type(prior.displayName) == "string" and prior.displayName or layoutName
    local answer = hs.dialog.blockAlert("Replace saved layout?",
      '"' .. label .. '" has the same name. Replace it with the current windows?', "Replace", "Cancel", "warning")
    if answer ~= "Replace" then return end
  end
  self._saving = true
  self:_saveSnapshot(layoutName, true, function(count, saveError)
    self._saving = false
    if not count then
      hs.alert.show("▦ DeskGrid did not save this layout\n" .. saveError, 8)
      return
    end
    self:_toast(string.format('Saved "%s" (%d windows)', layoutName, count))
  end, text)
end

function obj:listAndPick()
  local layouts = self:_loadLayouts()
  local choices = {}

  for name, layout in pairs(layouts.layouts or {}) do
    if type(layout) == "table" and layout.kind == "snapshot" and type(layout.windows) == "table" then
      table.insert(choices, {
        text = type(layout.displayName) == "string" and layout.displayName or name,
        subText = string.format("%d windows, %s", #(layout.windows or {}), layout.saved_at or "unknown date"),
        layoutName = name
      })
    end
  end

  local chooser = hs.chooser.new(function(choice)
    if choice then
      self:_applyLayout(choice.layoutName)
    end
  end)

  chooser:placeholderText("Load a saved layout")
  chooser:choices(choices)
  chooser:show()
end

function obj:explainSmartStart()
  return self:previewSmart()
end

function obj:closeMinimizedWindows()
  self:_toast("Use a layout to minimize overflow. Undo restores it.")
end

function obj:simulateFirstLaunch()
  local config = {
    version = 2,
    firstRunComplete = false,
    defaultLayout = "smart",
    showMenuBar = true,
    updated_at = self:_now()
  }
  self:_saveConfig(config)
  self:firstLaunch()
end

function obj:_candidateWindows()
  local windows = {}

  for _, win in ipairs(hs.window.orderedWindows()) do
    if self:_isCandidateWindow(win) then
      local app = win:application()
      local bundle = app and app:bundleID() or ""
      local appName = app and app:name() or bundle
      local title = win:title() or ""
      table.insert(windows, {
        win = win,
        order = #windows + 1,
        pid = app and app:pid() or nil,
        bundle = bundle,
        appName = appName or "Unknown",
        title = title,
        role = self:_roleFor(bundle, appName, title),
        screen = win:screen() or hs.screen.primaryScreen()
      })
    end
  end

  return windows
end

function obj:_isCandidateWindow(win)
  if not win or not win:isVisible() or win:isMinimized() or win:isFullScreen() then
    return false
  end
  if not self:_isUserFacing(win) then
    return false
  end

  local app = win:application()
  local bundle = app and app:bundleID() or ""
  if self.excludedBundles[bundle] then
    return false
  end

  local frame = win:frame()
  if not frame or frame.w < 220 or frame.h < 160 then
    return false
  end

  return true
end

function obj:_roleFor(bundle, appName, title)
  local haystack = string.lower(table.concat({ bundle or "", appName or "", title or "" }, " "))
  for _, rule in ipairs(self.roleRules) do
    for _, pattern in ipairs(rule.patterns) do
      if haystack:find(pattern, 1, true) then
        return rule.role
      end
    end
  end
  return "utility"
end

function obj:_slotFrame(screenFrame, region, index, count, gap)
  local stackGap = count > 1 and gap or 0
  local rawX = screenFrame.x + screenFrame.w * region.x
  local rawY = screenFrame.y + screenFrame.h * region.y
  local rawW = screenFrame.w * region.w
  local rawH = screenFrame.h * region.h
  local slotH = (rawH - gap * 2 - stackGap * (count - 1)) / count

  return {
    x = math.floor(rawX + gap),
    y = math.floor(rawY + gap + (index - 1) * (slotH + stackGap)),
    w = math.floor(rawW - gap * 2),
    h = math.floor(slotH)
  }
end

function obj:_moveWindow(win, frame)
  if not win then return end
  if win:isFullScreen() then
    win:setFullScreen(false)
  end
  win:setFrame(frame, 0)
end

function obj:_saveSnapshot(layoutName, includeAllVisible, callback, displayName)
  self:_currentFinderPaths(function(finderPaths, finderError, finderNoFolder)
    if finderError then callback(nil, finderError); return end
    finderNoFolder = finderNoFolder or {}
  local screen = hs.screen.primaryScreen()
  local screenFrame = screen and screen:frame() or { w = 0, h = 0 }
  local layoutWindows, bundleCounts = {}, {}
  local source = includeAllVisible and self:_listAllWindows() or hs.window.orderedWindows()

  for _, win in ipairs(source) do
    local app = self:_isCandidateWindow(win) and win:application() or nil
    -- A Finder view without a folder path cannot be reopened from a snapshot.
    if app and app:bundleID() == "com.apple.finder" and finderNoFolder[win:title() or ""] then app = nil end
    do
      if app then
        local frame = win:frame()
        local bundle = app:bundleID() or "unknown"
        bundleCounts[bundle] = (bundleCounts[bundle] or 0) + 1
        local title = win:title() or ""
        local finderPath = nil
        if bundle == "com.apple.finder" then
          local paths = finderPaths[title] or {}
          finderPath = table.remove(paths, 1)
          if not finderPath then callback(nil, "DeskGrid could not read the path for Finder window " .. title .. "."); return end
        end
        table.insert(layoutWindows, {
          bundle = bundle,
          title = title,
          id = win:id(), pid = app:pid(), processIdentity = self:_processIdentity(app:pid()),
          screenId = win:screen() and win:screen():id(),
          screenUUID = win:screen() and win:screen():getUUID(),
          screen = win:screen() and self:_plainFrame(win:screen():frame()),
          path = finderPath,
          frame = {
            x = math.floor(frame.x),
            y = math.floor(frame.y),
            w = math.floor(frame.w),
            h = math.floor(frame.h)
          }
        })
      end
    end
  end

  if #layoutWindows == 0 then callback(nil, "No windows to save. Saved layouts were not changed."); return end
  local layouts = self:_loadLayouts()
  if layouts.error then callback(nil, layouts.error); return end
  layouts.layouts[layoutName] = {
    kind = "snapshot",
    displayName = displayName or layoutName,
    saved_at = self:_now(),
    screen = {
      x = math.floor(screenFrame.x or 0), y = math.floor(screenFrame.y or 0),
      w = math.floor(screenFrame.w), h = math.floor(screenFrame.h),
    },
    windows = layoutWindows
  }
  if not self:_saveLayouts(layouts) then callback(nil, "DeskGrid could not write the layout file."); return end
  callback(#layoutWindows)
  end)
end

function obj:_currentFinderPaths(callback)
  local finder = hs.application.get("com.apple.finder")
  if not finder then callback({}); return end
  -- Ask Finder (Automation) only when a Finder window is open.
  -- The CoreGraphics list is fast and does not wait for a busy Finder.
  local hasWindow, pid = false, finder:pid()
  local ok, list = pcall(hs.window.list, true)
  for _, info in ipairs(ok and type(list) == "table" and list or {}) do
    if info.kCGWindowOwnerPID == pid and info.kCGWindowLayer == 0 then hasWindow = true; break end
  end
  if not ok then hasWindow = true end
  if not hasWindow then callback({}); return end
  local script = [[
set output to ""
with timeout of 8 seconds
  tell application "Finder"
    set finderWindows to get Finder windows
    repeat with finderWindow in finderWindows
      try
        set output to output & (name of finderWindow as text) & tab & POSIX path of (target of finderWindow as alias) & linefeed
      on error errorMessage
        -- Computer, Recents, AirDrop and Network views have no folder path.
        -- Only a folder or disk target without a path is a capture failure.
        set targetClass to missing value
        try
          set targetClass to class of (target of finderWindow)
        end try
        if targetClass is folder or targetClass is disk then
          set output to output & "CAPTURE ERROR:" & tab & errorMessage & linefeed
        else
          set output to output & "NO FOLDER:" & tab & (name of finderWindow as text) & linefeed
        end if
      end try
    end repeat
  end tell
end timeout
return output
]]
  self:_runAppleScriptAsync(script, function(ok, result)
    if not ok or type(result) ~= "string" or result:find("CAPTURE ERROR:", 1, true) then
      callback(nil, "DeskGrid could not capture all Finder paths.")
      return
    end
    local paths, noFolder = {}, {}
    for line in result:gmatch("[^\r\n]+") do
      local noFolderTitle = line:match("^NO FOLDER:\t(.+)$")
      local title, path = line:match("^([^\t]+)\t(.+)$")
      if noFolderTitle then
        noFolder[noFolderTitle] = true
      elseif title and path then
        local normalized = path:gsub("/$", "")
        -- Repeated windows for one folder are interchangeable. Only differing
        -- targets are ambiguous when matching the captured paths by title.
        if paths[title] and paths[title][1] ~= normalized then
          callback(nil, "DeskGrid cannot safely distinguish two Finder windows named " .. title .. ".")
          return
        end
        paths[title] = paths[title] or {}
        table.insert(paths[title], normalized)
      end
    end
    -- Folder windows are matched by title, so a view without a folder must
    -- not share its title with a folder window.
    for title in pairs(noFolder) do
      if paths[title] then
        callback(nil, "DeskGrid cannot safely distinguish two Finder windows named " .. title .. ".")
        return
      end
    end
    callback(paths, nil, noFolder)
  end)
end

function obj:_applyLayout(layoutName)
  if not self:_claimRun() then return end
  local guard=self:_asyncGuard(function(err)
    self:_releaseRun(); self:_toast("Could not prepare layout: " .. err)
  end)
  guard(function() self:_currentFinderPaths(guard(function(paths, finderError)
    -- A busy Finder must not stop the layout. Without live paths, Finder
    -- windows are matched by their folder title instead.
    if finderError then print("[DeskGrid] Finder paths unavailable; matching Finder windows by title.") end
    self.savedFinderTargets = (not finderError) and paths or nil
    self:_runFactory(function() return self:_createSavedPlan(layoutName) end)
  end)) end)()
end

-- One run at a time. A run that never reached its final callback is cleared
-- after runTimeoutSeconds, so DeskGrid cannot stay "already active".
function obj:_claimRun()
  local now = hs.timer.secondsSinceEpoch()
  if self.activeRun then
    if not self._runStartedAt then self._runStartedAt = now end
    if now - self._runStartedAt < self.runTimeoutSeconds then
      self:_toast("DeskGrid is already active")
      return false
    end
    print("[DeskGrid] cleared a run that did not finish in " .. self.runTimeoutSeconds .. " s")
  end
  self.activeRun, self._runStartedAt = true, now
  return true
end

function obj:_releaseRun()
  self.activeRun, self._runStartedAt = false, nil
end

-- Build the plan from the windows that are open now and arrange them.
-- Slots without an open window stay empty. DeskGrid never launches apps.
function obj:_runFactory(factory)
  local ok, plan = pcall(factory)
  if not ok then plan = { error = "Could not prepare layout: " .. tostring(plan) } end
  if type(plan) ~= "table" then plan = { error = "Could not prepare layout: invalid plan" } end
  self:_runPlan(plan, true)
end

function obj:_leaveEmpty(plan, label)
  table.insert(plan.missing, label)
end

function obj:_newPlan(kind, items)
  return {
    kind = kind,
    createdAt = self:_now(),
    items = items or {},
    keep = {},
    placements = {},
    close = {},
    quitTargets = {},
    openRequests = {},
    missing = {},
  }
end

-- Ask Accessibility only for apps that own a normal-layer window in the fast
-- CoreGraphics list (front to back, minimized and other-Space windows
-- included). Helper processes such as WebKit content processes own none, but
-- each one can take more than a second to answer an Accessibility query.
function obj:_windowOwnerScan()
  local frontOrder, owners, ownerList, onscreen = {}, {}, {}, {}
  local ok, list = pcall(hs.window.list, true)
  if not ok or type(list) ~= "table" then return nil end
  for index, info in ipairs(list) do
    if info.kCGWindowLayer == 0 and info.kCGWindowNumber then
      frontOrder[info.kCGWindowNumber] = frontOrder[info.kCGWindowNumber] or index
      if info.kCGWindowIsOnscreen then onscreen[info.kCGWindowNumber] = true end
      local pid = info.kCGWindowOwnerPID
      if pid and not owners[pid] then owners[pid] = true; ownerList[#ownerList + 1] = pid end
    end
  end
  return frontOrder, ownerList, onscreen
end

obj.helperPatterns = { "%.webkit%.", "helper", "xpc", "agent", "service", "extension", "daemon", "ssh-askpass" }

function obj:_isHelperProcess(bundle, name)
  local text = string.lower(bundle .. " " .. name)
  for _, pattern in ipairs(self.helperPatterns) do
    if text:find(pattern) then return true end
  end
  return false
end

function obj:_listAllWindows()
  local frontOrder, ownerList, onscreen = self:_windowOwnerScan()
  if not frontOrder then
    -- Fall back to the complete (slower) Hammerspoon enumeration.
    local order = {}
    for index, win in ipairs(hs.window.orderedWindows()) do
      if win:id() then order[win:id()] = index end
    end
    return hs.window.allWindows(), order, {}
  end
  local windows, owners = {}, {}
  for _, pid in ipairs(ownerList) do owners[pid] = true end
  local apps = {}
  for _, pid in ipairs(ownerList) do
    local app = hs.application.applicationForPID(pid)
    if app then apps[#apps + 1] = app end
  end
  -- Some apps (Ollama, for example) have an Accessibility window that the
  -- CoreGraphics list omits. Query them too, but skip background helpers.
  for _, app in ipairs(hs.application.runningApplications()) do
    local pid, bundle = app:pid(), app:bundleID() or ""
    if not owners[pid] and app:kind() >= 0 and not self:_isHelperProcess(bundle, app:name() or "") then
      owners[pid] = true
      apps[#apps + 1] = app
    end
  end
  for _, app in ipairs(apps) do
    if not self.excludedBundles[app:bundleID() or ""] then
      local ok, appWindows = pcall(app.allWindows, app)
      if ok and type(appWindows) == "table" then
        for _, win in ipairs(appWindows) do windows[#windows + 1] = win end
      end
    end
  end
  return windows, frontOrder, onscreen
end

function obj:_allUserWindows()
  local allWindows, frontOrder, onscreen = self:_listAllWindows()

  local items, seen, processIdentities = {}, {}, {}
  for _, win in ipairs(allWindows) do
    local id = win:id()
    local app = win:application()
    if id and app and not seen[id] and self:_isUserFacing(win) then
      seen[id] = true
      local frame = win:frame()
      local bundle = app:bundleID() or ""
      local title = win:title() or ""
      local pid = app:pid()
      if processIdentities[pid] == nil then
        processIdentities[pid] = self:_processIdentity(pid) or false
      end
      table.insert(items, {
        id = id,
        win = win,
        pid = pid,
        processIdentity = processIdentities[pid] or nil,
        bundle = bundle,
        appName = app:name() or bundle or "Unknown",
        title = title,
        frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h },
        minimized = win:isMinimized(),
        -- Some apps (CotEditor) can report a window as minimized while the
        -- WindowServer still draws it on screen. Such a window is resynced.
        ghostMinimized = onscreen[id] and win:isMinimized() or false,
        fullScreen = win:isFullScreen(),
        screenId = win:screen() and win:screen():id(),
        order = frontOrder[id] or (10000 + #items),
        role = self:_roleFor(bundle, app:name(), title),
      })
    end
  end
  table.sort(items, function(a, b) return a.order < b.order end)
  return items
end

function obj:_isUserFacing(win)
  if not win then return false end
  -- Temporary system panels cannot fill saved app slots or accept layout sizes.
  if win.subrole and win:subrole() == "AXSystemDialog" then return false end
  local app = win:application()
  local bundle = app and app:bundleID() or ""
  if self.excludedBundles[bundle] then return false end
  local frame = win:frame()
  if not frame or frame.w < 60 or frame.h < 40 then return false end
  if win:isStandard() then return true end
  return (win:title() or "") ~= "" and frame.w >= 180 and frame.h >= 120
end

function obj:_takeItem(items, used, bundle, title, exact)
  if not title or title == "" then
    for _, item in ipairs(items) do
      if item.bundle == bundle and not used[item.id] then
        used[item.id] = true
        return item
      end
    end
    return nil
  end
  for _, item in ipairs(items) do
    if item.bundle == bundle and item.title == title and not used[item.id] then
      used[item.id] = true
      return item
    end
  end
  if not exact then
    for _, item in ipairs(items) do
      if item.bundle == bundle and self:_contains(item.title, title) and not used[item.id] then
        used[item.id] = true
        return item
      end
    end
  end
  return nil
end

function obj:_takeTitle(items, used, title, bundle)
  for _, item in ipairs(items) do
    if item.title == title and (not bundle or item.bundle == bundle) and not used[item.id] then
      used[item.id] = true
      return item
    end
  end
  return nil
end

function obj:_keepPlacement(plan, item, frame, label)
  if not item then return false end
  plan.keep[item.id] = true
  table.insert(plan.placements, { item = item, frame = frame, label = label })
  return true
end

function obj:_chatBundle(items)
  for _, item in ipairs(items) do
    if item.bundle == "com.openai.codex" then return "com.openai.codex" end
  end
  return "com.openai.chat"
end

function obj:_defaultSlot(frame, column, row, rows)
  local horizontalGap, verticalGap, cursor = 0, math.min(self:_gap(frame), 7), 0
  for index = 1, column - 1 do cursor = cursor + self.defaultFractions[index] end
  local rawX = frame.x + frame.w * cursor
  local rawW = frame.w * self.defaultFractions[column]
  local rawY, rawH
  if column == 5 and rows == 3 then
    local rowFractions = { 0.47, 0.25, 0.28 }
    local rowCursor = 0
    for index = 1, row - 1 do rowCursor = rowCursor + rowFractions[index] end
    rawY = frame.y + frame.h * rowCursor
    rawH = frame.h * rowFractions[row]
  else
    rawY = frame.y + (row - 1) * frame.h / rows
    rawH = frame.h / rows
  end
  return {
    x = math.floor(rawX + horizontalGap),
    y = math.floor(rawY + verticalGap),
    w = math.floor(rawW - horizontalGap * 2),
    h = math.floor(rawH - verticalGap * 2),
  }
end

function obj:_finderTargets()
  -- These are the three canonical Finder windows in the built-in layout.
  -- Avoid a synchronous Finder query while planning because Finder can block
  -- Hammerspoon's event loop when it is busy.
  local targets = {
    Projects = { HOME .. "/Projects" },
    Screenshots = { HOME .. "/Pictures/Screenshots" },
    Downloads = { HOME .. "/Downloads" },
  }
  for title, paths in pairs(self.savedFinderTargets or {}) do targets[title] = paths end
  return targets
end

function obj:_takeFinder(items, used, targets, path)
  local wanted = path:gsub("/$", "")
  for _, item in ipairs(items) do
    if item.bundle == "com.apple.finder" and not used[item.id] then
      for _, target in ipairs(targets[item.title] or {}) do
        if target == wanted then
          used[item.id] = true
          return item
        end
      end
    end
  end
  return nil
end

function obj:_createDefaultPlan()
  local screen = hs.screen.primaryScreen()
  if not screen then return { error = "No primary screen", openRequests = {} } end
  local frame, items = screen:frame(), self:_allUserWindows()
  local plan, used = self:_newPlan("default", items), {}
  local function take(bundle, title, exact) return self:_takeItem(items, used, bundle, title, exact) end
  local function keep(item, column, row, rows, label)
    return self:_keepPlacement(plan, item, self:_defaultSlot(frame, column, row, rows), label)
  end

  local normalTerminals = {}
  for _, item in ipairs(items) do
    if item.bundle == "com.apple.Terminal" then
      table.insert(normalTerminals, item)
    end
  end
  table.sort(normalTerminals, function(a, b)
    if a.minimized ~= b.minimized then return not a.minimized end
    if a.frame.y ~= b.frame.y then return a.frame.y < b.frame.y end
    if a.frame.x ~= b.frame.x then return a.frame.x < b.frame.x end
    return a.order < b.order
  end)
  -- Each slot takes a window that is open now. A slot without one stays empty.
  local function slot(item, column, row, rows, label)
    if not keep(item, column, row, rows, label) then self:_leaveEmpty(plan, label) end
  end

  for row = 1, 3 do
    local item = normalTerminals[row]
    if item then used[item.id] = true end
    slot(item, 1, row, 3, "Terminal " .. row)
  end

  slot(take("com.anthropic.claudefordesktop"), 2, 1, 2, "Claude")
  slot(take(self:_chatBundle(items)), 2, 2, 2, "ChatGPT")
  slot(take("com.apple.Safari"), 3, 1, 2, "Safari")
  slot(take("com.google.Chrome"), 3, 2, 2, "Google Chrome main")
  slot(take("com.coteditor.CotEditor"), 4, 1, 4, "CotEditor")

  local finderSpecs = {
    { label = "Finder Projects", path = HOME .. "/Projects" },
    { label = "Finder Screenshots", path = HOME .. "/Pictures/Screenshots" },
    { label = "Finder Downloads", path = HOME .. "/Downloads" },
  }
  local finderTargets = self:_finderTargets()
  for index, spec in ipairs(finderSpecs) do
    slot(self:_takeFinder(items, used, finderTargets, spec.path), 4, index + 1, 4, spec.label)
  end

  slot(take("com.apple.iphonesimulator"), 5, 1, 3, "Simulator")
  slot(take("com.google.Chrome"), 5, 2, 3, "Google Chrome secondary")
  slot(take("com.apple.Music"), 5, 3, 3, "Music")

  slot(take("com.apple.iCal"), 6, 1, 4, "Calendar")
  slot(take("com.apple.MobileSMS"), 6, 2, 4, "Messages")
  slot(take("com.apple.mail"), 6, 3, 4, "Mail")
  slot(take("com.apple.Notes"), 6, 4, 4, "Notes")

  self:_completeCleanupPlan(plan)
  return plan
end

function obj:_createSmartPlan()
  local items, screens = self:_allUserWindows(), self:_screens()
  if #screens == 0 then return {error="No screen available",openRequests={}} end
  local focusedId = self:_focusedUserId(items)
  local planner = dofile(self.sourceDirectory .. "/smart.lua")
  local options = self:_loadConfig().smart
  local plan = planner.plan(items, screens, focusedId, type(options)=="table" and options or {})
  plan.kind, plan.items, plan.createdAt = "smart", items, self:_now()
  plan.openRequests, plan.close, plan.quitTargets = {}, {}, {}
  return plan
end

function obj:_createSavedPlan(layoutName)
  local layout = self:_loadLayouts().layouts[layoutName]
  if type(layout) ~= "table" or layout.kind ~= "snapshot" then
    return { error = "Layout not found: " .. tostring(layoutName), openRequests = {} }
  end
  local valid, validationError = self:_validateLayout(layout)
  if not valid then return {error=validationError,openRequests={}} end
  local screen = hs.screen.primaryScreen()
  if not screen then return { error = "No primary screen", openRequests = {} } end
  local frame, items = screen:frame(), self:_allUserWindows()
  local plan, used = self:_newPlan("saved", items), {}
  plan.layoutName = layoutName
  local finderPaths = {
    Projects = HOME .. "/Projects",
    Screenshots = HOME .. "/Pictures/Screenshots",
    Downloads = HOME .. "/Downloads",
  }
  local finderTargets = self:_finderTargets()
  local original = layout.screen or { x = 0, y = 0, w = frame.w, h = frame.h }
  local specs, selected = layout.windows or {}, {}
  local function finderPathOf(spec)
    return (spec.bundle or "") == "com.apple.finder" and (spec.path or finderPaths[spec.title]) or nil
  end
  -- Reserve exact window identities first, so that the title of a closed
  -- window cannot take a surviving window away from its own saved slot.
  for index, spec in ipairs(specs) do
    local bundle = spec.bundle or ""
    if spec.id and not finderPathOf(spec) and bundle ~= "com.obsproject.obs-studio" then
      for _, candidate in ipairs(items) do
        if candidate.id == spec.id and candidate.pid == spec.pid
            and candidate.processIdentity == spec.processIdentity and candidate.bundle == bundle and not used[candidate.id] then
          selected[index], used[candidate.id] = candidate, true
          break
        end
      end
    end
  end
  for index, spec in ipairs(specs) do
    local bundle = spec.bundle or ""
    local finderPath = finderPathOf(spec)
    if selected[index] then
      -- Matched by exact identity above.
    elseif finderPath then
      selected[index] = self:_takeFinder(items, used, finderTargets, finderPath)
      -- Without live Finder paths (Finder busy), a same-title Finder window
      -- is the best available match for this folder slot.
      if not selected[index] and not self.savedFinderTargets then
        selected[index] = self:_takeTitle(items, used, spec.title, "com.apple.finder")
      end
    elseif bundle ~= "com.obsproject.obs-studio" and (spec.title or "") ~= "" then
      selected[index] = self:_takeItem(items, used, bundle, spec.title, true)
    end
  end
  -- Complete all title-based matches before any same-bundle fallback can
  -- consume a window that belongs to a later saved slot.
  for index, spec in ipairs(specs) do
    local bundle = spec.bundle or ""
    if not selected[index] and bundle ~= "com.obsproject.obs-studio" and bundle ~= "com.apple.finder"
      and bundle ~= "org.python.python" then
      selected[index] = self:_takeItem(items, used, bundle, spec.title, false)
    end
  end
  for index, spec in ipairs(specs) do
    local bundle = spec.bundle or ""
    if not selected[index] and bundle ~= "com.obsproject.obs-studio" and bundle ~= "com.apple.finder"
      and bundle ~= "org.python.python" then
      selected[index] = self:_takeItem(items, used, bundle, nil, false)
    end
  end
  for index, spec in ipairs(specs) do
    local bundle = spec.bundle or ""
    if bundle ~= "com.obsproject.obs-studio" then
      local item = selected[index]
      if item then
        local target, source = frame, spec.screen or original
        if spec.screenUUID or spec.screenId then
          for _, candidate in ipairs(hs.screen.allScreens()) do
            if (type(spec.screenUUID) == "string" and candidate:getUUID() == spec.screenUUID)
                or (type(spec.screenUUID) ~= "string" and candidate:id() == spec.screenId) then
              target = self:_plainFrame(candidate:frame()); break
            end
          end
        end
        local sx, sy = target.w / source.w, target.h / source.h
        plan.keep[item.id] = true
        table.insert(plan.placements, {
          item = item,
          label = spec.title,
          frame = self:_clampToFrame({
            x = math.floor(target.x + (spec.frame.x - (source.x or 0)) * sx),
            y = math.floor(target.y + (spec.frame.y - (source.y or 0)) * sy),
            w = math.floor(spec.frame.w * sx),
            h = math.floor(spec.frame.h * sy),
          }, target),
        })
      else
        -- The app or window is not open. Leave this slot empty.
        self:_leaveEmpty(plan, spec.title ~= "" and spec.title or bundle)
      end
    end
  end
  self:_completeCleanupPlan(plan)
  return plan
end

-- Keep a scaled saved frame on its display, so that a layout saved on a
-- larger or differently placed display cannot push a window off screen.
function obj:_clampToFrame(f, b)
  local w, h = math.min(f.w, b.w), math.min(f.h, b.h)
  return {
    x = math.floor(math.max(b.x, math.min(f.x, b.x + b.w - w))),
    y = math.floor(math.max(b.y, math.min(f.y, b.y + b.h - h))),
    w = math.floor(w), h = math.floor(h),
  }
end

function obj:_completeCleanupPlan(plan)
  -- Layout is reversible. Overflow remains open and can be restored with Undo.
  plan.close, plan.quitTargets, plan.minimize = {}, {}, {}
  plan.reasons = plan.reasons or {}
  for _, item in ipairs(plan.items) do
    if not plan.keep[item.id] then
      if item.ghostMinimized and not self.protectedBundles[item.bundle] then
        item.resync = true
        table.insert(plan.minimize, item)
        plan.reasons[item.id] = "Reported minimized but still on screen; minimized again"
      elseif item.minimized or item.fullScreen or self.protectedBundles[item.bundle] then
        plan.keep[item.id] = true
        plan.reasons[item.id] = "Left unchanged"
      else
        table.insert(plan.minimize, item)
        plan.reasons[item.id] = "Outside this layout; kept open in the Dock"
      end
    end
  end
end

function obj:_isUncapturedBrowser(item)
  if not item then return false end
  if item.bundle == "com.apple.Safari" or item.bundle == "com.google.Chrome" then return false end
  if self.uncapturedBrowserBundles[item.bundle] then return true end
  local identity = string.lower((item.bundle or "") .. " " .. (item.appName or ""))
  for _, pattern in ipairs({ "safari", "chrome", "chromium", "firefox", "browser", "arc", "edge", "brave", "opera", "vivaldi", "orion" }) do
    if identity:find(pattern, 1, true) then return true end
  end
  return false
end

function obj:previewDefault()
  local name = self:_loadConfig().defaultLayout
  if name == "smart" then return self:previewSmart() end
  local saved = type(name) == "string" and self:_loadLayouts().layouts[name] or nil
  if type(saved) ~= "table" or saved.kind ~= "snapshot" then
    if name ~= "development" then return self:previewSmart() end
    return self:_showPreview(self:_createDefaultPlan())
  end
  do
    self:_currentFinderPaths(function(paths, err)
      if err then self:_toast(err); return end
      self.savedFinderTargets = paths
      self:_showPreview(self:_createSavedPlan(name))
    end)
  end
end

function obj:previewSmart()
  return self:_showPreview(self:_createSmartPlan())
end

function obj:previewLayout(layoutName)
  self:_currentFinderPaths(function(paths, err)
    if err then self:_toast(err); return end
    self.savedFinderTargets = paths
    self:_showPreview(self:_createSavedPlan(layoutName))
  end)
end

function obj:_serializablePlan(plan)
  local data = {
    kind = plan.kind,
    layout_name = plan.layoutName,
    error = plan.error,
    created_at = plan.createdAt,
    keep = {}, close = {}, minimize = {}, open = {}, quit = {}, missing = plan.missing or {},
  }
  local placementById = {}
  for _, placement in ipairs(plan.placements or {}) do placementById[placement.item.id] = placement end
  for _, item in ipairs(plan.items or {}) do
    if plan.keep[item.id] then
      local placement = placementById[item.id]
      table.insert(data.keep, {
        window_id = item.id, pid = item.pid, bundle_id = item.bundle, app_name = item.appName, title = item.title,
        target_frame = placement and placement.frame or nil,
        unchanged = placement == nil,
        reason = (plan.reasons or {})[item.id] or (placement and placement.reason),
      })
    end
  end
  for _, item in ipairs(plan.close or {}) do
    table.insert(data.close, {
      window_id = item.id, pid = item.pid, bundle_id = item.bundle, app_name = item.appName, title = item.title,
    })
  end
  for _, item in ipairs(plan.minimize or {}) do
    table.insert(data.minimize, {window_id=item.id,app_name=item.appName,title=item.title,
      reason=(plan.reasons or {})[item.id] or "Kept open in the Dock"})
  end
  for _, target in ipairs(plan.quitTargets or {}) do
    table.insert(data.quit, {
      pid = target.pid, bundle_id = target.bundle, app_name = target.appName,
    })
  end
  for _, request in ipairs(plan.openRequests or {}) do
    table.insert(data.open, {
      kind = request.kind, label = request.label, bundle_id = request.bundle,
      path = request.path, launchd_label = request.launchdLabel,
    })
  end
  return data
end

function obj:_asyncGuard(onError)
  local failed = false
  return function(fn)
    return function(...)
      if failed then return end
      local ok, err = pcall(fn, ...)
      if not ok then failed = true; onError(tostring(err)) end
    end
  end
end

function obj:_runPlan(plan, alreadyClaimed)
  if not alreadyClaimed and not self:_claimRun() then return end
  if plan.error then self:_releaseRun(); self:_toast(plan.error); return end
  if #(plan.placements or {})==0 and #(plan.minimize or {})==0 then
    self:_releaseRun(); self:_toast("No windows need arranging; previous Undo kept"); return
  end
  -- Capture only identity and geometry, before any move or minimization.
  -- No external disk, browser contents or Terminal scrollback are involved.
  local ok, undo, undoError = pcall(self._saveUndo,self,plan)
  if not ok then undoError,undo=undo,nil end
  if not undo then
    self:_releaseRun()
    self:_toast("Could not save Undo: " .. tostring(undoError))
    return
  end
  local guard = self:_asyncGuard(function(err) self:_rollbackRun(undo,"Layout failed: " .. err) end)
  guard(function()
  self:_preparePlacements(plan.placements, guard(function()
    -- A window that stays full screen is reported as not arranged below.
    self:_placeAndVerify(plan.placements, guard(function(_, placementResult)
      local report=placementResult or {failed={},skipped=0,adjusted=0}
      local failed,skipped=#report.failed,report.skipped or 0
      local moved=#(plan.placements or {})-skipped-failed
      -- Best effort: one window that refuses its frame must not undo every
      -- other window. Roll back only when no window could be arranged.
      if #(plan.placements or {})>0 and moved<=0 and failed>0 then
        local first=report.failed[1]
        self:_rollbackRun(undo, "No window could be arranged (" .. first.bundle .. ": " .. first.reason .. ")"); return
      end
      self:_applyMinimizes(plan.minimize or {}, guard(function(minimized, unresolved)
        self:_finishRun(plan, {moved=moved, minimized=minimized, adjusted=report.adjusted or 0,
          placementDetails=report, failed=report.failed, skipped=skipped,
          unresolved=unresolved or 0, empty=plan.missing or {}, snapshot=undo.path})
      end))
    end), true)
  end))
  end)()
end

function obj:_preparePlacements(placements, callback)
  local fullScreen = {}
  for _, placement in ipairs(placements or {}) do
    local win = placement.item and placement.item.win
    if win and self:_identityMatches(win,placement.item) and win:isFullScreen() then
      table.insert(fullScreen, win)
      win:setFullScreen(false)
    end
  end
  if #fullScreen == 0 then callback(true); return end
  self:_pollUntil(6, function()
    for _, win in ipairs(fullScreen) do if win:isFullScreen() then return false end end
    return true
  end, callback)
end

function obj:_uid()
  if not self._cachedUid then
    local output = hs.execute("/usr/bin/id -u") or ""
    self._cachedUid = tonumber(output:match("^%s*(%d+)%s*$"))
  end
  return self._cachedUid or 0
end

function obj:_pollUntil(seconds, condition, callback)
  local deadline = hs.timer.secondsSinceEpoch() + seconds
  local timer, finished
  local function poll()
    if finished then return end
    local ok, done = pcall(condition)
    if (ok and done) or hs.timer.secondsSinceEpoch() >= deadline then
      finished = true
      if timer then timer:stop(); self._timers[timer] = nil end
      timer = false
      callback(ok and done or false)
    end
  end
  poll()
  -- The first check can already finish the poll; then no timer is needed.
  if timer == false then return end
  timer = hs.timer.doEvery(0.25, poll)
  self._timers[timer] = true
end

function obj:_runAppleScriptAsync(script, callback, timeoutSeconds)
  local task, timeoutTimer, finished
  -- osascript writes its stdout to a private temporary file, not to the hs.task pipe.
  -- The pipe deadlocks above 64 KB without a streaming callback and can drop trailing
  -- chunks under load with one (observed 2026-09-03 with large Terminal scrollback captures).
  local outputPath = hs.fs.temporaryDirectory() .. "deskgrid-osascript-" .. hs.host.uuid() .. ".out"
  local function readOutput()
    local file = io.open(outputPath, "rb")
    local content = file and file:read("a") or ""
    if file then file:close() end
    os.remove(outputPath)
    return content
  end
  local function finish(ok, standardOutput, standardError)
    if finished then return end
    finished = true
    if timeoutTimer then timeoutTimer:stop() end
    if task then self.captureTasks[task] = nil end
    callback(ok, standardOutput or "", standardError or "")
  end
  local errorChunks = {}
  task = hs.task.new("/bin/sh", function(exitCode, _, standardError)
    finish(exitCode == 0, readOutput(), table.concat(errorChunks) .. (standardError or ""))
  end, function(_, _, standardError)
    table.insert(errorChunks, standardError or "")
    return true
  end, { "-c", 'umask 077; set -C; exec /usr/bin/osascript -e "$1" > "$2"', "deskgrid-osascript", script, outputPath })
  if not task then
    finish(false, "", "Could not start osascript")
    return
  end
  self.captureTasks[task] = true
  if not task:start() then
    finish(false, "", "Could not start osascript")
    return
  end
  if finished then return end
  timeoutTimer = hs.timer.doAfter(timeoutSeconds or 10, function()
    if task and task:isRunning() then task:terminate() end
    os.remove(outputPath)
    finish(false, "", "osascript timed out")
  end)
end

function obj:_runTaskAsync(executable, arguments, callback, timeoutSeconds)
  local task, timeoutTimer, finished
  local function finish(ok, standardOutput, standardError)
    if finished then return end
    finished = true
    if timeoutTimer then timeoutTimer:stop() end
    if task then self.captureTasks[task] = nil end
    callback(ok, standardOutput or "", standardError or "")
  end
  local outputChunks, errorChunks = {}, {}
  task = hs.task.new(executable, function(exitCode, standardOutput, standardError)
    finish(exitCode == 0, table.concat(outputChunks) .. (standardOutput or ""), table.concat(errorChunks) .. (standardError or ""))
  end, function(_, standardOutput, standardError)
    table.insert(outputChunks, standardOutput or "")
    table.insert(errorChunks, standardError or "")
    return true
  end, arguments or {})
  if not task then finish(false, "", "Could not start task"); return end
  self.captureTasks[task] = true
  if not task:start() then finish(false, "", "Could not start task"); return end
  if finished then return end
  timeoutTimer = hs.timer.doAfter(timeoutSeconds or 10, function()
    if task and task:isRunning() then task:terminate() end
    finish(false, "", "Task timed out")
  end)
end

function obj:_frameFits(actual, target)
  return math.abs(actual.x-target.x)<=16 and math.abs(actual.y-target.y)<=16
    and actual.w<=target.w+16 and actual.h<=target.h+16
    and actual.w>=target.w*0.85 and actual.h>=target.h*0.85
end

function obj:_placeAndVerify(placements, callback, allowAdjustment)
  local started=hs.timer.secondsSinceEpoch()
  local entries={}
  for _,p in ipairs(placements or {})do
    entries[#entries+1]={placement=p,target=self:_plainFrame(p.frame),writes=0,stable=0}
  end
  local function inspect(e,write)
    local p=e.placement
    local w=p.item and p.item.win
    if e.skipped then return true end
    if not self:_identityMatches(w,p.item) then
      e.stable=0;e.reason="window closed or changed"
      -- An app can exit after the Undo checkpoint. Leave its stale handle
      -- alone and keep the other placements; never resolve a replacement by
      -- title or bundle. Undo and ambiguous/live identities remain strict.
      if allowAdjustment and not hs.window.get(p.item.id)
          and not hs.application.applicationForPID(p.item.pid)
          and self:_processIdentity(p.item.pid,true)==nil then
        e.skipped=true;e.reason="app exited during arrangement";return true
      end
      return false
    end
    if write then
      if w:isMinimized() then w:unminimize() end
      w:setFrame(e.target,0)
      e.writes=e.writes+1
    end
    local f=self:_plainFrame(w:frame())
    local old=e.actual
    if old and math.abs(old.x-f.x)<1 and math.abs(old.y-f.y)<1
        and math.abs(old.w-f.w)<1 and math.abs(old.h-f.h)<1 then
      e.stable=e.stable+1
    else e.stable=0 end
    e.actual=f
    e.reason="requested frame was not accepted"
    return self:_frameFits(f,e.target) and not w:isMinimized()
  end
  local function check(e,write)
    local ok,fits=pcall(inspect,e,write)
    if not ok then e.stable=0;e.reason="Accessibility request failed" end
    e.fits=ok and fits or false
    return e.fits
  end
  for _,e in ipairs(entries)do check(e,true) end
  self:_pollUntil(4,function()
    local all=true
    local elapsed=hs.timer.secondsSinceEpoch()-started
    for _,e in ipairs(entries)do
      -- Observe between bounded retries. Repeated AX writes can restart an
      -- asynchronous resize and prevent a busy application from settling.
      local retry=(e.writes==1 and elapsed>=1) or (e.writes==2 and elapsed>=2.5)
      if not check(e,not e.fits and retry) then all=false end
    end
    return all
  end,function(complete)
    local report={adjusted=0,skipped=0,failed={},windows={}}
    local pending={}
    if not complete and allowAdjustment then
      local screenOK,screens=pcall(self._screens,self)
      if not screenOK then screens={} end
      for _,e in ipairs(entries)do
        local f,t=e.actual,e.target
        if not e.fits and e.stable>=2 and f and
            (f.w>t.w+16 or f.h>t.h+16) and f.w>=t.w*0.85 and f.h>=t.h*0.85
            and math.abs(f.x-t.x)<=16 and math.abs(f.y-t.y)<=16 then
          local screen
          for _,s in ipairs(screens)do if s.id==e.placement.item.screenId then screen=s;break end end
          if screen and f.w<=screen.frame.w and f.h<=screen.frame.h then
            local b=screen.frame
            e.target={x=math.max(b.x,math.min(t.x,b.x+b.w-f.w)),
              y=math.max(b.y,math.min(t.y,b.y+b.h-f.h)),w=f.w,h=f.h}
            e.adjusted=true
            check(e,true)
            pending[#pending+1]=e
          end
        end
      end
    end
    local function finish()
      local success=true
      for _,e in ipairs(entries)do
        check(e,false)
        local detail={id=e.placement.item.id,bundle=e.placement.item.bundle,
          requested=self:_plainFrame(e.placement.frame),actual=e.actual,adjusted=e.adjusted or false}
        report.windows[#report.windows+1]=detail
        if e.skipped then
          report.skipped=report.skipped+1;detail.skipped=true;detail.reason=e.reason
        elseif e.fits then
          if e.adjusted then report.adjusted=report.adjusted+1 end
        else
          success=false;detail.reason=e.reason;report.failed[#report.failed+1]=detail
        end
      end
      callback(success,report)
    end
    if #pending==0 then finish();return end
    self:_pollUntil(2,function()
      local all=true
      for _,e in ipairs(pending)do if not check(e,false) then all=false end end
      return all
    end,finish)
  end)
end


-- The process start time distinguishes a live app from a later process that
-- reuses its PID. It is cached briefly; `fresh` forces a new `ps` lookup.
function obj:_processIdentity(pid, fresh)
  local numericPID = tonumber(pid)
  if not numericPID then return nil end
  numericPID = math.floor(numericPID)
  local now = hs.timer.secondsSinceEpoch()
  local cached = self._identityCache[numericPID]
  if not fresh and cached and now - cached.at < self.identityCacheSeconds then return cached.value end
  local output, ok = hs.execute("/bin/ps -p " .. tostring(numericPID) .. " -o lstart=")
  local identity = nil
  if ok then
    identity = tostring(output or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if identity == "" then identity = nil end
  end
  self._identityCache[numericPID] = { value = identity, at = now }
  return identity
end

function obj:_finishRun(plan, result)
  self:_releaseRun()
  self.lastResult = result
  local config = self:_loadConfig()
  config.version, config.firstRunComplete = 4, true
  config.lastAppliedLayout, config.updated_at = plan.layoutName or plan.kind, self:_now()
  local saved = self:_saveConfig(config)
  local message = string.format("%d arranged · %d minimized", result.moved, result.minimized or 0)
  if (result.adjusted or 0)>0 then message=message .. "\n" .. result.adjusted .. " windows fitted to app minimum size" end
  if #(result.empty or {})>0 then
    message=message .. "\n" .. #result.empty .. " slots left empty (not open)"
  end
  local notArranged={}
  for _,detail in ipairs(result.failed or {}) do notArranged[#notArranged+1]=self:_appLabel(detail.bundle) end
  if #notArranged>0 then message=message .. "\nNot arranged: " .. table.concat(notArranged, ", ") end
  if (result.skipped or 0)>0 then message=message .. "\n" .. result.skipped .. " windows closed during arrangement" end
  if (result.unresolved or 0)>0 then message=message .. "\n" .. result.unresolved .. " windows did not minimize" end
  if not saved then message=message .. "\nCould not save last-used preference" end
  print("[DeskGrid] " .. message:gsub("\n", " · "))
  hs.alert.show("▦ DeskGrid\n" .. message .. "\nUndo is available in the ▦ menu", 5)
end

function obj:_appLabel(bundle)
  local app = bundle and hs.application.get(bundle)
  return (app and app:name()) or bundle or "unknown app"
end

function obj:_writeText(path, content)
  if hs.fs.symlinkAttributes(path, "mode") then return false end
  local temporary, made = hs.execute("/usr/bin/mktemp " .. self:_shellQuote(path .. ".tmp.XXXXXX"))
  if not made then return false end
  temporary = tostring(temporary or ""):gsub("%s+$", "")
  local prefix = path .. ".tmp."
  if temporary:sub(1, #prefix) ~= prefix or #temporary ~= #prefix + 6 or temporary:find("[\r\n]") then
    return false
  end
  if temporary == "" or hs.fs.symlinkAttributes(temporary, "mode") == "link" then
    if temporary ~= "" then os.remove(temporary) end
    return false
  end
  local file = io.open(temporary, "w")
  if not file then
    os.remove(temporary)
    return false
  end
  local writeOK = file:write(content or "") ~= nil
  local flushOK = writeOK and file:flush() ~= nil
  local closeOK = file:close() ~= nil
  local permissionOK = writeOK and flushOK and closeOK and self:_setPrivatePermissions(temporary)
  if not permissionOK or hs.fs.symlinkAttributes(path, "mode") then
    os.remove(temporary)
    return false
  end
  local renamed = os.rename(temporary, path)
  if not renamed then os.remove(temporary) end
  return renamed and true or false
end

function obj:_setPrivatePermissions(path)
  if hs.fs.symlinkAttributes(path, "mode") == "link" then return false end
  local kind = hs.fs.attributes(path, "mode")
  local mode = kind == "directory" and "700" or "600"
  local _, ok = hs.execute("/bin/chmod -h " .. mode .. " " .. self:_shellQuote(path))
  if ok ~= true then return false end
  local attributes = hs.fs.symlinkAttributes(path)
  local expected = kind == "directory" and "rwx------" or "rw-------"
  return attributes and attributes.mode == kind and attributes.permissions == expected
end

function obj:_privateDirectoryBoundary(path, requirePrivate)
  local attributes = hs.fs.symlinkAttributes(path)
  if not attributes or attributes.mode ~= "directory" then return false end
  local ownerIsCurrentUser = attributes.uid == self:_uid()
  local ownerIsRootVolumeBoundary = not requirePrivate and attributes.uid == 0
  if not ownerIsCurrentUser and not ownerIsRootVolumeBoundary then return false end
  local permissions = attributes.permissions or ""
  local groupWrite = permissions:sub(5, 5) == "w"
  local otherWrite = permissions:sub(8, 8) == "w"
  if groupWrite or otherWrite then return false end
  return not requirePrivate or permissions == "rwx------"
end

function obj:_writeAtomicJSON(path, value)
  local temporary = path .. ".tmp-" .. tostring(math.floor(hs.timer.secondsSinceEpoch() * 1000))
  local encoded = hs.json.encode(value, true)
  if not encoded or not self:_writeText(temporary, encoded .. "\n") then return false end
  local ok = os.rename(temporary, path)
  if not ok then os.remove(temporary) end
  return ok and true or false
end

function obj:_safeFileName(text)
  local value = tostring(text):gsub("[^%w%._-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if value == "" then value = "capture" end
  return value:sub(1, 160)
end

function obj:_contains(text, needle)
  return string.lower(text or ""):find(string.lower(needle or ""), 1, true) ~= nil
end

function obj:_matchesAny(text, patterns)
  for _, pattern in ipairs(patterns) do if self:_contains(text, pattern) then return true end end
  return false
end

function obj:_workspaceSummary()
  local candidates = self:_candidateWindows()
  local screens = {}
  local roles = {}
  for _, item in ipairs(candidates) do
    screens[tostring(item.screen:id())] = true
    roles[item.role] = (roles[item.role] or 0) + 1
  end

  local screenCount = 0
  for _ in pairs(screens) do screenCount = screenCount + 1 end
  if screenCount == 0 then screenCount = #hs.screen.allScreens() end

  return string.format("I found %d movable windows on %d display%s.", #candidates, screenCount, screenCount == 1 and "" or "s")
end

function obj:openNewestCleanupSnapshot()
  local path = self.stateRoot
  if hs.fs.attributes(path, "mode") ~= "directory" then self:_toast("No Undo history yet"); return end
  hs.task.new("/usr/bin/open", nil, {path}):start()
end

function obj:_setupMenu()
  if self.menubar then self.menubar:delete() end
  self.menubar = hs.menubar.new()
  if not self.menubar then return end
  self.menubar:setTitle("▦"):setTooltip("DeskGrid 4 · Arrange with Undo")
  self.menubar:setMenu(function()
    local name=self:_loadConfig().defaultLayout
    local layout=self:_loadLayouts().layouts[name]
    if type(layout)~="table" then layout=nil end
    local label=layout and (type(layout.displayName)=="string" and layout.displayName or name) or (name=="development" and "Development layout" or "Smart layout")
    return {
      {title="Default: " .. label .. "    ^⌥⌘0",fn=function()self:applyDefault()end},
      {title="Smart layout    ^⌥⌘1",fn=function()self:applySmartStart()end},
      {title="Preview Smart Layout…",fn=function()self:previewSmart()end},
      {title="Preview default layout…",fn=function()self:previewDefault()end},
      {title="Undo last arrangement",fn=function()self:undoLast()end},
      {title="Drag windows to swap",checked=self.dragSwap and self.dragSwap.enabled or false,
        fn=function()self.dragSwap:toggle()end},
      {title="Undo last window swap",fn=function()self.dragSwap:undo()end},
      {title="-"},
      {title="Save current layout…    ^⌥⌘S",fn=function()self:saveCurrent()end},
      {title="Load saved layout…    ^⌥⌘L",fn=function()self:listAndPick()end},
      {title="Open Undo history",fn=function()self:openNewestCleanupSnapshot()end},
      {title="Show shortcuts",fn=function()self:_showShortcutHint()end},
      {title="-"},
      {title="Windows stay open. Overflow is minimized.",disabled=true},
      {title="Apps that are not open leave their slot empty.",disabled=true},
      {title="DeskGrid " .. self.version,disabled=true},
    }
  end)
end

function obj:_ensureStateFiles()
  if hs.fs.symlinkAttributes(self.layoutsFile) then
    self:_setPrivatePermissions(self.layoutsFile)
  else
    self:_saveLayouts({ version = 2, layouts = {} })
  end
  if hs.fs.symlinkAttributes(self.configFile) then
    self:_setPrivatePermissions(self.configFile)
  else
    self:_saveConfig({
      version = 2,
      firstRunComplete = false,
      defaultLayout = "smart",
      showMenuBar = true,
      updated_at = self:_now()
    })
  end
end

function obj:_completeFirstLaunch(defaultLayout)
  local config = self:_loadConfig()
  config.version = 2
  config.firstRunComplete = true
  config.defaultLayout = defaultLayout or "smart"
  config.updated_at = self:_now()
  self:_saveConfig(config)
end

function obj:_loadLayouts()
  local f = io.open(self.layoutsFile, "r")
  if not f then
    if hs.fs.symlinkAttributes(self.layoutsFile) then
      return { version = 4, layouts = {}, error = "Saved layouts cannot be read; the existing file was preserved" }
    end
    return { version = 2, layouts = {} }
  end
  local content = f:read("*a")
  f:close()
  local ok, layouts = pcall(hs.json.decode, content)
  if ok and type(layouts) == "table" then
    if type(layouts.layouts) ~= "table" then return {version=4,layouts={},error="Saved layouts are damaged; the existing file was preserved"} end
    layouts.version = layouts.version or 2
    layouts.layouts = layouts.layouts or {}
    return layouts
  end
  return { version = 4, layouts = {}, error="Saved layouts are damaged; the existing file was preserved" }
end

function obj:_saveLayouts(layouts)
  return self:_writeAtomicJSON(self.layoutsFile, layouts)
end

function obj:_loadConfig()
  local defaults = {
    version = 2,
    firstRunComplete = false,
    defaultLayout = "smart",
    showMenuBar = true,
    updated_at = self:_now()
  }
  local f = io.open(self.configFile, "r")
  if not f then
    if hs.fs.symlinkAttributes(self.configFile) then
      defaults.error = "DeskGrid preferences cannot be read; the existing file was preserved"
    end
    return defaults
  end
  local content = f:read("*a")
  f:close()
  local ok, config = pcall(hs.json.decode, content)
  if ok and type(config) == "table" then
    for key, value in pairs(defaults) do
      if config[key] == nil then config[key] = value end
    end
    return config
  end
  defaults.error="DeskGrid preferences are damaged; the existing file was preserved"
  return defaults
end

function obj:_saveConfig(config)
  if config.error then return false end
  return self:_writeAtomicJSON(self.configFile, config)
end

function obj:_gap(frame)
  if frame.w >= 2600 then return 10 end
  return 8
end

function obj:_slug(text)
  local slug = tostring(text):lower():gsub("[^a-z0-9_-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if slug == "" then slug = "desk-" .. os.date("%Y%m%d-%H%M%S") end
  return slug
end

function obj:_shellQuote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

function obj:_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function obj:_toast(message)
  hs.alert.show("▦ " .. message, 2)
end

function obj:_shortcutText()
  return table.concat({"^⌥⌘0  Default layout", "^⌥⌘1  Smart layout",
    "^⌥⌘S  Save current layout", "^⌥⌘L  Load a saved layout",
    "Drag a window onto another to swap their positions and sizes.",
    "Hold Option while dragging to bypass swapping.",
    "▦ menu  Preview, Undo and saved layouts", "Overflow stays open in the Dock.",
    "Apps that are not open are not launched; their slot stays empty."}, "\n")
end

function obj:_showShortcutHint()
  hs.alert.show("▦ DeskGrid\n" .. self:_shortcutText(), 5)
end

function obj:_plainFrame(f)
  return {x=f.x,y=f.y,w=f.w,h=f.h}
end

function obj:_screens()
  local screens={}
  for _, screen in ipairs(hs.screen.allScreens()) do
    screens[#screens+1]={id=screen:id(),name=screen:name(),frame=self:_plainFrame(screen:frame())}
  end
  table.sort(screens,function(a,b)return tostring(a.id)<tostring(b.id)end)
  return screens
end

function obj:_validateLayout(layout)
  local function finite(n)return type(n)=="number" and n==n and math.abs(n)<1000000 end
  local function frame(f, screen)return type(f)=="table" and finite(screen and (f.x or 0) or f.x) and finite(screen and (f.y or 0) or f.y)
    and finite(f.w) and finite(f.h) and f.w>0 and f.h>0 end
  if type(layout)~="table" or type(layout.windows)~="table" or #layout.windows>200 or (layout.screen and not frame(layout.screen,true)) then
    return false,"Saved layout has invalid screen or window data"
  end
  for _, spec in ipairs(layout.windows) do
    if type(spec)~="table" or type(spec.bundle)~="string" or type(spec.title)~="string"
        or not frame(spec.frame) or (spec.screen and not frame(spec.screen,true))
        or (spec.path and (type(spec.path)~="string" or spec.path:sub(1,1)~="/")) then
      return false,"Saved layout contains an invalid window"
    end
  end
  return true
end

function obj:_identityMatches(win, item)
  if not win or win:id() ~= item.id then return false end
  local app=win:application()
  return app and app:pid()==item.pid and (app:bundleID() or "")==item.bundle
    and item.processIdentity ~= nil and self:_processIdentity(item.pid)==item.processIdentity
end

function obj:_focusedUserId(items)
  local focused=hs.window.focusedWindow()
  local id=focused and focused:id()
  for _,item in ipairs(items)do if item.id==id then return id end end
  for _,item in ipairs(items)do if not item.minimized then return item.id end end
end

function obj:_saveUndo(plan)
  if not self:_ensureUndoDirectory() then return nil,"Local Undo folder is not writable" end
  local state={schema_version=1,created_at=self:_now(),windows={},screens=self:_screens()}
  local current=self:_allUserWindows()
  state.focusedId=self:_focusedUserId(current)
  local affected={}
  for _, p in ipairs(plan.placements or {})do affected[p.item.id]=true end
  for _, item in ipairs(plan.minimize or {})do affected[item.id]=true end
  for _, item in ipairs(current)do
    if affected[item.id] then
      if not self:_identityMatches(item.win,item) then return nil,"A window changed identity; retry the layout" end
      state.windows[#state.windows+1]={id=item.id,pid=item.pid,processIdentity=item.processIdentity,
        bundle=item.bundle,frame=item.frame,minimized=item.minimized,fullScreen=item.fullScreen,screenId=item.screenId}
    end
  end
  for id in pairs(affected)do
    local found=false
    for _, item in ipairs(state.windows)do if item.id==id then found=true;break end end
    if not found then return nil,"A window disappeared; retry the layout" end
  end
  state.path=self.stateRoot .. "/undo-" .. os.date("!%Y%m%dT%H%M%SZ") .. "-" .. hs.host.uuid() .. ".json"
  if not self:_writeAtomicJSON(state.path,state) then return nil,"Could not write local Undo checkpoint" end
  local file=io.open(state.path,"r")
  local raw=file and file:read("*a"); if file then file:close() end
  local ok, decoded=pcall(hs.json.decode,raw or "")
  if not ok or not decoded or #decoded.windows~=#state.windows then return nil,"Could not verify local Undo checkpoint" end
  if not self:_writeAtomicJSON(self.stateRoot .. "/latest.json",state) then return nil,"Could not save latest Undo" end
  self._undo=state
  return state
end

function obj:_ensureUndoDirectory()
  -- Inspect each existing ancestor. Never follow a substituted state directory.
  local home=os.getenv("HOME")
  if not self:_privateDirectoryBoundary(home,false) then return false end
  local root=home .. "/.hammerspoon"
  if not self:_privateDirectoryBoundary(root,false) then return false end
  local mode=hs.fs.symlinkAttributes(self.stateRoot,"mode")
  if mode and mode~="directory" then return false end
  if not mode and not hs.fs.mkdir(self.stateRoot) then return false end
  return self:_setPrivatePermissions(self.stateRoot) and self:_privateDirectoryBoundary(self.stateRoot,true)
end

function obj:_applyMinimizes(items, callback)
  local resync={}
  for _, item in ipairs(items)do
    local win=item.win
    if self:_identityMatches(win,item) and not win:isFullScreen() and not self.protectedBundles[item.bundle] then
      if item.resync then win:unminimize(); resync[#resync+1]=item else win:minimize() end
    end
  end
  if #resync>0 then
    local t
    t=hs.timer.doAfter(0.6,function()
      self._timers[t]=nil
      for _,item in ipairs(resync)do
        if self:_identityMatches(item.win,item) then pcall(function() item.win:minimize() end) end
      end
    end)
    self._timers[t]=true
  end
  local minimized=0
  self:_pollUntil(4,function()
    minimized=0
    for _,item in ipairs(items)do
      if self:_identityMatches(item.win,item) and item.win:isMinimized() then minimized=minimized+1 end
    end
    return minimized==#items
  end,function() callback(minimized,#items-minimized) end)
end

function obj:_readUndo()
  if self._undo and self:_validateUndo(self._undo) then return self._undo end
  local path=self.stateRoot .. "/latest.json"
  local attr=hs.fs.symlinkAttributes(path)
  if not attr or attr.mode~="file" or attr.uid~=self:_uid() or attr.permissions~="rw-------" then return nil end
  local file=io.open(path,"r");if not file then return nil end
  local raw=file:read("*a");file:close()
  local ok,state=pcall(hs.json.decode,raw)
  if not ok or not self:_validateUndo(state) then return nil end
  return state
end

function obj:_validateUndo(state)
  if type(state)~="table" or state.schema_version~=1 or type(state.windows)~="table" or #state.windows>200 then return false end
  local seen={}
  for _,item in ipairs(state.windows)do
    if type(item)~="table" or type(item.id)~="number" or seen[item.id]
      or type(item.pid)~="number" or item.pid<1 or type(item.processIdentity)~="string"
      or type(item.bundle)~="string" or type(item.minimized)~="boolean" or type(item.fullScreen)~="boolean" then return false end
    local valid=self:_validateLayout({windows={{bundle=item.bundle,title="",frame=item.frame}}})
    if not valid then return false end
    seen[item.id]=true
  end
  return true
end

function obj:_restoreUndo(state,callback)
  local placements,restore,skipped={}, {},0
  local guard=self:_asyncGuard(function(err) callback(false,skipped,err) end)
  guard(function()
  local current={}
  for _,item in ipairs(self:_allUserWindows())do current[item.id]=item end
  local screens=self:_screens()
  for _,saved in ipairs(state.windows)do
    local item=current[saved.id]
    if item and self:_identityMatches(item.win,saved) and type(saved.frame)=="table" then
      local f=self:_plainFrame(saved.frame)
      local screen
      for _,candidate in ipairs(screens)do if candidate.id==saved.screenId then screen=candidate;break end end
      -- A disconnected display must not strand a window off screen.
      if not screen then
        screen=screens[1]
        if screen then
          local b=screen.frame
          f.w,f.h=math.min(f.w,b.w),math.min(f.h,b.h)
          f.x,f.y=math.max(b.x,math.min(f.x,b.x+b.w-f.w)),math.max(b.y,math.min(f.y,b.y+b.h-f.h))
        end
      end
      placements[#placements+1]={item=item,frame=f}
      restore[#restore+1]={item=item,saved=saved}
    else skipped=skipped+1 end
  end
  self:_preparePlacements(placements,guard(function(ready)
    if not ready then callback(false,skipped);return end
    self:_placeAndVerify(placements,guard(function(placed)
      for _,entry in ipairs(restore)do
        if self:_identityMatches(entry.item.win,entry.saved) then
          if entry.saved.minimized then entry.item.win:minimize() else entry.item.win:unminimize() end
          if entry.saved.fullScreen then entry.item.win:setFullScreen(true) end
        else skipped=skipped+1 end
      end
      self:_pollUntil(6,function()
        for _,entry in ipairs(restore)do
          if self:_identityMatches(entry.item.win,entry.saved) then
            if entry.item.win:isMinimized()~=entry.saved.minimized
                or entry.item.win:isFullScreen()~=entry.saved.fullScreen then return false end
          end
        end
        return true
      end,guard(function(statesRestored)
        local focus=current[state.focusedId]
        if focus and not focus.win:isMinimized() then focus.win:focus() end
        callback(placed and statesRestored,skipped)
      end))
    end))
  end))
  end)()
end

function obj:_rollbackRun(undo,reason)
  self:_restoreUndo(undo,function(restored,skipped)
    self:_releaseRun()
    self.lastResult={error=reason,rolledBack=restored,skipped=skipped}
    self:_toast(reason .. (restored and "; previous layout restored" or "; use Undo to retry restoration"))
  end)
end

function obj:undoLast()
  local state=self:_readUndo()
  if not state then self:_toast("No Undo checkpoint yet");return end
  if not self:_claimRun() then return end
  self:_restoreUndo(state,function(restored,skipped)
    self:_releaseRun()
    self.lastUndoResult={restored=restored,skipped=skipped}
    self:_toast((restored and "Previous layout restored" or "Some windows could not be restored")
      .. (skipped>0 and ("; " .. skipped .. " closed or changed windows skipped") or ""))
  end)
end

function obj:_inventorySignature(items)
  local values={}
  for _,item in ipairs(items)do
    local f=item.frame
    values[#values+1]=table.concat({tostring(item.id),tostring(item.pid),item.processIdentity or "",item.bundle,
      tostring(item.minimized),tostring(item.fullScreen),tostring(f.x),tostring(f.y),tostring(f.w),tostring(f.h),
      string.format("%q",item.title or "")},"|")
  end
  table.sort(values)
  for _,screen in ipairs(self:_screens())do
    local f=screen.frame
    values[#values+1]=table.concat({tostring(screen.id),f.x,f.y,f.w,f.h},"|")
  end
  return table.concat(values,"\n")
end

function obj:_showPreview(plan)
  if plan.error then self:_toast(plan.error);return end
  if self.previewWindow then self.previewWindow:delete();self.previewWindow=nil end
  local data=self:_serializablePlan(plan)
  local signature=self:_inventorySignature(plan.items)
  local finderSignature=self:_finderSignature(self.savedFinderTargets or {})
  local view,checking
  local renderer=dofile(self.sourceDirectory .. "/preview.lua")
  local controller=hs.webview.usercontent.new("deskgrid")
  controller:setCallback(function(message)
    if self.previewWindow~=view or not view or not view:isVisible() or type(message.body)~="string" then return end
    local action=message.body
    if action=="cancel" then self.previewWindow:delete();self.previewWindow=nil;return end
    if action=="refresh" then
      if plan.kind=="smart" then self:previewSmart()
      elseif plan.layoutName then self:previewLayout(plan.layoutName)
      else self:previewDefault() end
      return
    end
    if action=="apply" then
      if self.activeRun then self:_toast("DeskGrid is already active");return end
      if signature~=self:_inventorySignature(self:_allUserWindows()) then
        self:_toast("The desktop changed. Refresh this preview before applying.");return
      end
      local previewWindow=self.previewWindow
      local function apply(paths,err)
        checking=false
        if self.previewWindow~=previewWindow or not previewWindow:isVisible() or self.activeRun then return end
        if err then self:_toast(err);return end
        if signature~=self:_inventorySignature(self:_allUserWindows())
            or (paths and finderSignature~=self:_finderSignature(paths)) then
          self:_toast("The desktop changed. Refresh this preview before applying.");return
        end
        if paths then self.savedFinderTargets=paths end
        self.previewWindow:delete();self.previewWindow=nil
        self:_runPlan(plan)
      end
      if plan.layoutName then
        if checking then return end
        checking=true
        self:_currentFinderPaths(apply)
      else apply() end
    end
  end)
  local screen=hs.screen.mainScreen() or hs.screen.primaryScreen()
  local f=screen:frame();local w,h=math.min(1120,f.w-60),math.min(920,f.h-60)
  view=hs.webview.new({x=f.x+(f.w-w)/2,y=f.y+(f.h-h)/2,w=w,h=h},
    {javaScriptCanOpenWindowsAutomatically=false,privateBrowsing=true},controller)
  self.previewWindow=view
  view:windowCallback(function(action,closingView)
    if action=="closing" and self.previewWindow==closingView then
      self.previewWindow=nil
      checking=false
    end
  end)
  view:windowStyle({"titled","closable","resizable"}):windowTitle("DeskGrid · Layout preview")
    :allowNewWindows(false):allowTextEntry(true):closeOnEscape(true):deleteOnClose(true)
    :html(renderer.render(data,self:_screens())):show():bringToFront(true)
  self.lastPreview=data
  return data
end

function obj:_finderSignature(paths)
  local values={}
  for title,targets in pairs(paths)do
    for _,path in ipairs(targets)do
      values[#values+1]=string.format("%q:%q",title,path)
    end
  end
  table.sort(values)
  return table.concat(values,"\n")
end

return obj
