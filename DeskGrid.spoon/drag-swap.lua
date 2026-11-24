-- DeskGrid: swap two existing layout slots by dragging a window onto another.
-- Observe mouse events only; normal clicks, text drags and resizes pass through.
local M = {}
local Swap = {}
Swap.__index = Swap

local function frame(f)
  return {x=f.x, y=f.y, w=f.w, h=f.h}
end

local function contains(f, p, inset)
  inset = inset or 0
  return p.x >= f.x+inset and p.x < f.x+f.w-inset
    and p.y >= f.y+inset and p.y < f.y+f.h-inset
end

local function fits(a, b, tolerance)
  tolerance = tolerance or 12
  return math.abs(a.x-b.x) <= tolerance and math.abs(a.y-b.y) <= tolerance
    and math.abs(a.w-b.w) <= tolerance and math.abs(a.h-b.h) <= tolerance
end

function M.new(owner)
  return setmetatable({owner=owner, enabled=false, busy=false,
    undoPath=owner.stateRoot .. "/drag-swap-undo.json"}, Swap)
end

function Swap:_screens()
  local result = {}
  for _,s in ipairs(hs.screen.allScreens()) do
    local f=s:frame()
    result[#result+1]=table.concat({s:id(),f.x,f.y,f.w,f.h}, ":")
  end
  table.sort(result)
  return table.concat(result, "|")
end

function Swap:_clearPreview()
  if self.preview then self.preview:delete(); self.preview=nil end
  self.previewId=nil
end

function Swap:_cancel()
  self.gesture=nil
  if self.previewTimer then self.previewTimer:stop(); self.previewTimer=nil end
  self:_clearPreview()
end

function Swap:_resolve(item)
  local app=hs.application.applicationForPID(item.pid)
  local win=app and app:getWindow(item.id)
  if not win or not win:isStandard() or not win:isVisible()
      or win:isMinimized() or win:isFullScreen() then return nil end
  local bundle=app:bundleID() or ""
  if self.owner.excludedBundles[bundle] then return nil end
  if item.bundle and item.bundle~=bundle then return nil end
  return win
end

-- CG snapshots are fast and do not ask every app for Accessibility information
-- inside the mouse callback. Preserve the original z-order and both slot sizes.
function Swap:_begin(point)
  self:_cancel()
  if not self.enabled or self.busy or self.owner.activeRun then return end
  local items={}
  for _,v in ipairs(hs.window.list() or {}) do
    local b=v.kCGWindowBounds
    -- The computer-use cursor is a click-through layer-0 window. It must not
    -- cover the title bar or become a drop target during an assisted session.
    local cursorOverlay=false
    if v.kCGWindowOwnerName=="ChatGPT Computer Use" then
      local app=hs.application.applicationForPID(v.kCGWindowOwnerPID)
      cursorOverlay=app and app:bundleID()=="com.openai.sky.CUAService"
    end
    if v.kCGWindowLayer==0 and v.kCGWindowIsOnscreen and b and not cursorOverlay then
      items[#items+1]={id=v.kCGWindowNumber,pid=v.kCGWindowOwnerPID,
        frame={x=b.X,y=b.Y,w=b.Width,h=b.Height}}
    end
  end
  local source
  for _,item in ipairs(items) do
    if contains(item.frame,point) then source=item; break end
  end
  if not source or source.frame.w<160 or source.frame.h<100 then return end
  self.gesture={source=source,items=items,start=point,point=point,screens=self:_screens()}
end

function Swap:_moved(g)
  local win=self:_resolve(g.source)
  if not win then return nil end
  local f=win:frame()
  local before=g.source.frame
  -- Only an actual move qualifies. Resizing, selecting text, dragging tabs or
  -- files, and programmatic layout changes must not swap windows.
  if math.abs(f.w-before.w)>8 or math.abs(f.h-before.h)>8 then return nil end
  if math.abs(f.x-before.x)+math.abs(f.y-before.y)<24 then return nil end
  local dx,dy=g.point.x-g.start.x,g.point.y-g.start.y
  if math.abs((f.x-before.x)-dx)>48 or math.abs((f.y-before.y)-dy)>48 then return nil end
  return win
end

function Swap:_target(g)
  if contains(g.source.frame,g.point,4) then return nil end
  for _,item in ipairs(g.items) do
    if item.id~=g.source.id and contains(item.frame,g.point,8) then
      -- Do not reach through a dialog or another covering window to choose an
      -- obscured target. The first original window under the pointer wins.
      local win=self:_resolve(item)
      if win and fits(win:frame(),item.frame,4) then return item,win end
      return nil
    end
  end
end

function Swap:_preview()
  local g=self.gesture
  if not g or g.cancelled or hs.eventtap.checkKeyboardModifiers().alt
      or self.owner.activeRun or not self:_moved(g) then self:_clearPreview(); return end
  local target=self:_target(g)
  if not target then self:_clearPreview(); return end
  if self.previewId==target.id then return end
  self:_clearPreview()
  local f=target.frame
  self.preview=hs.canvas.new(f)
  self.preview:level(hs.canvas.windowLevels.overlay):behavior({"canJoinAllSpaces","stationary"})
  self.preview[1]={type="rectangle",action="strokeAndFill",roundedRectRadii={xRadius=10,yRadius=10},
    strokeColor={red=0.15,green=0.7,blue=1,alpha=0.95},strokeWidth=5,
    fillColor={red=0.1,green=0.6,blue=1,alpha=0.12}}
  self.preview[2]={type="text",text="⇄  Swap windows",textSize=22,textAlignment="center",
    textColor={white=1,alpha=1},frame={x=12,y=math.max(12,f.h/2-20),w=f.w-24,h=40}}
  self.preview:show()
  self.previewId=target.id
end

function Swap:_identity(win, original)
  local app=win:application()
  return {id=win:id(),pid=app:pid(),bundle=app:bundleID() or "",
    processIdentity=self.owner:_processIdentity(app:pid()),frame=frame(original)}
end

function Swap:_valid(item, win)
  return self.owner:_identityMatches(win,item) and win:isStandard()
    and win:isVisible() and not win:isFullScreen() and not win:isMinimized()
end

-- Check asynchronous AX results and retry a bounded number of times. If an
-- app cannot accept the other slot's size, restore both original slots.
function Swap:_place(pair, destinations, done, restoring)
  local attempts=0
  local function step()
    attempts=attempts+1
    local ok,err=pcall(function()
      for i,item in ipairs(pair) do
        if not self:_valid(item,item.win) then
          if not restoring then error("A window closed or changed") end
        elseif not fits(item.win:frame(),destinations[i]) then item.win:setFrame(destinations[i],0) end
      end
    end)
    if not ok then done(false,tostring(err)); return end
    self.placementTimer=hs.timer.doAfter(0.3,function()
      self.placementTimer=nil
      local success,accepted=pcall(function()
        for i,item in ipairs(pair) do
          if not self:_valid(item,item.win) or not fits(item.win:frame(),destinations[i]) then return false end
        end
        return true
      end)
      if success and accepted then done(true)
      elseif attempts<3 then step()
      else done(false,"An app cannot fit the other window's size") end
    end)
  end
  step()
end

function Swap:_run(pair, destinations, rollback, verb, callback)
  self.busy=true
  self.owner.activeRun=true
  local function finish(success,detail)
    self.busy=false
    self.owner.activeRun=false
    self.lastResult={success=success,action=verb,detail=detail,at=os.date("!%Y-%m-%dT%H:%M:%SZ")}
    if success then
      pcall(function() pair[1].win:focus() end)
    else
      self.owner:_toast(detail or "Could not swap these windows")
    end
    if callback then callback(success) end
  end
  self:_place(pair,destinations,function(success,reason)
    if success then finish(true); return end
    self:_place(pair,rollback,function(restored)
      finish(false,reason .. (restored and "; original positions restored" or "; restore was incomplete"))
    end,true)
  end)
end

function Swap:_drop(point, bypass, capturedGesture)
  local g=capturedGesture or self.gesture
  if g then g.point=point end
  if not capturedGesture then self:_cancel() end
  if not g or not g.dragged or g.cancelled or bypass or not self.enabled
      or self.busy or self.owner.activeRun or self:_screens()~=g.screens then return end
  local source=self:_moved(g)
  if not source then return end
  local target,targetWin=self:_target(g)
  if not target then return end
  local pair={self:_identity(source,g.source.frame),self:_identity(targetWin,target.frame)}
  pair[1].win,pair[2].win=source,targetWin
  if not pair[1].processIdentity or not pair[2].processIdentity then return end
  local undo={schema_version=1,screens=g.screens,windows={}}
  for i,item in ipairs(pair) do
    undo.windows[i]={id=item.id,pid=item.pid,bundle=item.bundle,
      processIdentity=item.processIdentity,frame=item.frame}
  end
  if not self.owner:_writeAtomicJSON(self.undoPath,undo) then
    self.owner:_toast("Could not save swap Undo; no swap performed"); return
  end
  local original={pair[1].frame,pair[2].frame}
  self:_run(pair,{original[2],original[1]},original,"swap")
end

function Swap:undo()
  if self.busy or self.owner.activeRun then return end
  local undo=hs.json.read(self.undoPath)
  if type(undo)~="table" or undo.schema_version~=1 or type(undo.windows)~="table"
      or #undo.windows~=2 or undo.screens~=self:_screens() then
    self.owner:_toast("No matching window swap to undo"); return
  end
  local pair=undo.windows
  for _,item in ipairs(pair) do
    if type(item)~="table" or type(item.id)~="number" or type(item.pid)~="number"
        or type(item.bundle)~="string" or type(item.processIdentity)~="string"
        or type(item.frame)~="table" then self.owner:_toast("Swap Undo is invalid"); return end
    for _,key in ipairs({"x","y","w","h"}) do
      local n=item.frame[key]
      if type(n)~="number" or n~=n or math.abs(n)>1000000
          or ((key=="w" or key=="h") and n<=0) then self.owner:_toast("Swap Undo is invalid"); return end
    end
    item.win=self:_resolve(item)
    if not item.win or not self:_valid(item,item.win) then
      self.owner:_toast("The swapped windows have closed or changed"); return
    end
  end
  local current={frame(pair[1].win:frame()),frame(pair[2].win:frame())}
  self:_run(pair,{pair[1].frame,pair[2].frame},current,"undo",function(success)
    if success then self.owner:_toast("Window swap undone") end
  end)
end

function Swap:toggle()
  local config=self.owner:_loadConfig()
  if config.error then self.owner:_toast(config.error); return end
  config.dragSwapEnabled=not self.enabled
  if not self.owner:_saveConfig(config) then self.owner:_toast("Could not save drag-swap preference"); return end
  self.enabled=config.dragSwapEnabled
  self:_cancel()
  self.owner:_toast("Drag to swap " .. (self.enabled and "on" or "off"))
end

function Swap:start()
  self:stop()
  local config=self.owner:_loadConfig()
  self.enabled=not config.error and config.dragSwapEnabled~=false
  local types=hs.eventtap.event.types
  self.tap=hs.eventtap.new({types.leftMouseDown,types.leftMouseDragged,types.leftMouseUp,types.keyDown},function(event)
    local ok,err=pcall(function()
      local kind=event:getType()
      if kind==types.keyDown then
        if self.gesture and event:getKeyCode()==53 then self.gesture.cancelled=true; self:_clearPreview() end
        return
      end
      if kind==types.leftMouseDown then
        self:_cancel()
        if not event:getFlags().alt then self:_begin(event:location()) end
      elseif kind==types.leftMouseDragged and self.gesture then
        self.gesture.point=event:location()
        self.gesture.dragged=true
        if not self.previewTimer then
          self.previewTimer=hs.timer.doEvery(0.12,function()
            local success,detail=pcall(self._preview,self)
            if not success then self:_cancel(); print("[DeskGrid drag-swap] " .. tostring(detail)) end
          end)
        end
      elseif kind==types.leftMouseUp then
        local point,bypass=event:location(),event:getFlags().alt
        local gesture=self.gesture
        self:_cancel()
        if not gesture or not gesture.dragged then return end
        -- Let macOS finish handling mouse-up before resizing either window.
        -- Keep a reference so that garbage collection cannot cancel the drop.
        self.dropTimer=hs.timer.doAfter(0.04,function()
          self.dropTimer=nil
          local success,detail=pcall(self._drop,self,point,bypass,gesture)
          if not success then self:_cancel(); print("[DeskGrid drag-swap] " .. tostring(detail)) end
        end)
      end
    end)
    if not ok then self:_cancel(); print("[DeskGrid drag-swap] " .. tostring(err)) end
    return false
  end):start()
  -- macOS can disable an event tap after a timeout. Re-enable the same tap,
  -- discard any stale gesture, and log recovery instead of replaying a drag.
  self.healthTimer=hs.timer.doEvery(15,function()
    if self.enabled and not self.tap:isEnabled() then
      self:_cancel()
      self.tap:start()
      print("[DeskGrid drag-swap] mouse observer restarted")
    end
  end)
  return self
end

function Swap:stop()
  self:_cancel()
  if self.tap then self.tap:stop(); self.tap=nil end
  if self.healthTimer then self.healthTimer:stop(); self.healthTimer=nil end
end

M.contains, M.fits = contains, fits
return M
