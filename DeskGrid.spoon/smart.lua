-- Pure Smart Layout planning. No desktop operations or input mutation.
-- order: lower values mean more recent use. maxWindows: per-screen limit
-- (default 12, hard ceiling 32). Pinned bundles stay unchanged, like OBS.
local M = {}
local min, max, floor = math.min, math.max, math.floor

local function finite(n)
  return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function validFrame(f)
  return type(f) == "table" and finite(f.x) and finite(f.y)
    and finite(f.w) and finite(f.h) and f.w > 0 and f.h > 0
end

local function idLess(a, b)
  if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
  return type(a) .. tostring(a) < type(b) .. tostring(b)
end

local function minimum(item)
  local name = string.lower((item.bundle or "") .. " " .. (item.appName or ""))
  -- Measured native minimum; smaller targets make WhatsApp reject the layout.
  if item.bundle == "net.whatsapp.WhatsApp" then return 800, 600 end
  if name:find("codex", 1, true) then return 650, 480 end
  if item.role == "terminal" or name:find("terminal", 1, true)
    or name:find("iterm", 1, true) then return 420, 260 end
  if item.role == "side" then return 500, 400 end
  -- Browsers, editors, and unknown applications use a conservative baseline.
  return 500, 360
end

local function intersects(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w
    and a.y < b.y + b.h and b.y < a.y + a.h
end

local function screenFor(item, screens)
  for _, screen in ipairs(screens) do
    if item.screenId == screen.id and
      (not validFrame(item.frame) or intersects(item.frame, screen.frame)) then
      return screen, "Kept on its display."
    end
  end
  local best, distance
  for _, screen in ipairs(screens) do
    local f = screen.frame
    local x = validFrame(item.frame) and item.frame.x + item.frame.w / 2 or f.x + f.w / 2
    local y = validFrame(item.frame) and item.frame.y + item.frame.h / 2 or f.y + f.h / 2
    local dx, dy = max(f.x - x, 0, x - f.x - f.w), max(f.y - y, 0, y - f.y - f.h)
    local d = dx * dx + dy * dy
    if not best or d < distance then best, distance = screen, d end
  end
  return best, "Assigned to the nearest display."
end

-- Each candidate has equal grid cells, or a large leading cell plus a grid.
-- The search is bounded by 32 windows and a fixed set of split ratios.
local function pack(items, f, gap, focusedId)
  local n = #items
  if n == 0 then return {} end
  local best, bestScore
  local function consider(rects, emphasis)
    if #rects ~= n then return end
    local smallest = math.huge
    for i, r in ipairs(rects) do
      local w, h = minimum(items[i])
      if r.w + 0.000001 < w or r.h + 0.000001 < h then return end
      smallest = min(smallest, min(r.w / w, r.h / h))
    end
    local score = smallest + (emphasis and 10 or 0)
    if not best or score > bestScore then best, bestScore = rects, score end
  end
  local function grids(region, first, lead)
    local count = n - first + 1
    for cols = 1, count do
      local rows = math.ceil(count / cols)
      local w = (region.w - gap * (cols - 1)) / cols
      local h = (region.h - gap * (rows - 1)) / rows
      local rects = {}
      if lead then rects[1] = lead end
      for j = 0, count - 1 do
        rects[first + j] = { x = region.x + (j % cols) * (w + gap),
          y = region.y + floor(j / cols) * (h + gap), w = w, h = h }
      end
      local emphasis = lead and items[1].id == focusedId
        and lead.w * lead.h >= w * h * 1.15
      consider(rects, emphasis)
    end
  end
  grids(f, 1)
  if n > 1 then
    for _, ratio in ipairs({ 0.4, 0.5, 0.6 }) do
      local w = (f.w - gap) * ratio
      grids({ x = f.x + w + gap, y = f.y, w = f.w - w - gap, h = f.h }, 2,
        { x = f.x, y = f.y, w = w, h = f.h })
      local h = (f.h - gap) * ratio
      grids({ x = f.x, y = f.y + h + gap, w = f.w, h = f.h - h - gap }, 2,
        { x = f.x, y = f.y, w = f.w, h = h })
    end
  end
  return best
end

local weights = { main = 60, side = 55, terminal = 45, utility = 10 }
local function bundleKey(item)
  -- Separate Python processes often host distinct small apps; keep them apart.
  if item.bundle == "org.python.python" then
    return item.bundle .. ":" .. tostring(item.pid or item.title or item.id)
  end
  if item.bundle and item.bundle ~= "" then return item.bundle end
  return item.appName or "Unknown"
end

function M.plan(items, screens, focusedId, options)
  options = options or {}
  local result = { placements = {}, minimize = {}, keep = {}, missing = {}, reasons = {} }
  local gap = finite(options.gap) and max(0, options.gap) or 12
  local limit = finite(options.maxWindows) and max(1, min(32, floor(options.maxWindows))) or 12
  local displays, groups, locations = {}, {}, {}
  for _, screen in ipairs(screens or {}) do
    if validFrame(screen.frame) then displays[#displays + 1] = screen end
  end
  table.sort(displays, function(a, b) return idLess(a.id, b.id) end)
  for _, screen in ipairs(displays) do groups[screen] = {} end
  local ordered = {}
  for _, item in ipairs(items or {}) do ordered[#ordered + 1] = item end
  table.sort(ordered, function(a, b) return idLess(a.id, b.id) end)
  local function keep(item, reason)
    result.keep[item.id], result.reasons[item.id] = true, reason
  end
  for _, item in ipairs(ordered) do
    local pinned = type(options.pinnedBundles)=="table" and options.pinnedBundles[item.bundle]
    if item.minimized then keep(item, "Already minimized. Left unchanged.")
    elseif item.fullScreen then keep(item, "Full screen. Left unchanged.")
    elseif item.bundle == "com.obsproject.obs-studio" then keep(item, "OBS is protected. Left unchanged.")
    elseif pinned then keep(item, "Pinned application. Left unchanged.")
    elseif #displays == 0 then keep(item, "No usable display. Left unchanged.")
    else
      local screen, reason = screenFor(item, displays)
      groups[screen][#groups[screen] + 1], locations[item.id] = item, reason
    end
  end
  for _, screen in ipairs(displays) do
    local pending, selected, counts = groups[screen], {}, {}
    local frames = {}
    local function score(item)
      local order = finite(item.order) and max(1, item.order) or 10000
      local count = counts[bundleKey(item)] or 0
      return (weights[item.role] or 20) + 40 / (1 + (order - 1) / 8)
        - count * (item.role == "utility" and 65 or 22)
    end
    while #pending > 0 do
      table.sort(pending, function(a, b)
        if (a.id == focusedId) ~= (b.id == focusedId) then return a.id == focusedId end
        local sa, sb = score(a), score(b)
        if sa ~= sb then return sa > sb end
        local oa = finite(a.order) and a.order or math.huge
        local ob = finite(b.order) and b.order or math.huge
        if oa ~= ob then return oa < ob end
        return idLess(a.id, b.id)
      end)
      local item = table.remove(pending, 1)
      local key = bundleKey(item)
      local duplicate = item.role == "utility" and (counts[key] or 0) > 0 and item.id ~= focusedId
      local trial
      if not duplicate and #selected < limit then
        selected[#selected + 1] = item
        trial = pack(selected, screen.frame, gap, focusedId)
        if not trial then selected[#selected] = nil end
      end
      if trial then
        frames = trial
        counts[key] = (counts[key] or 0) + 1
        local why = item.id == focusedId and "Focused window has priority."
          or "Selected by recent use, role, and application diversity."
        keep(item, why .. " " .. locations[item.id] .. " Minimum size respected.")
      elseif item.id == focusedId then
        keep(item, "Focused window cannot fit at minimum size. Left unchanged.")
      else
        result.minimize[#result.minimize + 1] = item
        result.reasons[item.id] = duplicate and "Duplicate utility window. Minimize for less clutter."
          or (#selected >= limit and "Display window limit reached. Minimize for later recovery."
          or "No readable layout space. Minimize for later recovery.")
      end
    end
    for i, item in ipairs(selected) do
      result.placements[#result.placements + 1] = { item = item, frame = frames[i],
        label = item.appName or item.bundle or "Window", reason = result.reasons[item.id] }
    end
  end
  return result
end

return M
