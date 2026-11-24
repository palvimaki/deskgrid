-- Local-only renderer. Window titles are untrusted text, never HTML or script.
local M={}
local function esc(v)
  return tostring(v or ""):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&#39;")
end
function M.render(data,screens)
  local moved,unchanged=0,0
  for _,item in ipairs(data.keep or {})do if item.target_frame then moved=moved+1 else unchanged=unchanged+1 end end
  local title=data.kind=="smart" and "A clearer desk, built around your work" or (data.layout_name or "Development desk")
  local out={[[<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';"><style>
:root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#e5edf3;background:#10191f}*{box-sizing:border-box}body{margin:0;padding:32px 36px 102px}small,.muted{color:#9fafbc}header{display:flex;justify-content:space-between;align-items:center}.brand{font-size:16px;font-weight:700;letter-spacing:.04em;color:#79d4c1}.version{border:1px solid #33434c;padding:6px 10px;border-radius:16px;font-size:12px}h1{font-size:29px;font-weight:650;line-height:1.2;margin:22px 0 9px}p{margin:0;line-height:1.5}.stats{display:flex;gap:12px;margin:24px 0}.stat{flex:1;padding:15px 18px;background:#1a2932;border:1px solid #2b414d;border-radius:12px}.stat strong{font-size:25px;margin-right:8px}.stat span{font-size:13px;color:#a8bdca}.display{background:#17232c;border:1px solid #344550;border-radius:10px;padding:12px;margin:18px 0}.screen-label{display:flex;justify-content:space-between;font-size:12px;margin-bottom:10px}.map{position:relative;width:100%;background:#0a1117;border-radius:5px;overflow:hidden}.tile{position:absolute;border:1px solid #63bda9;background:#214c48;color:#e1fff8;border-radius:4px;padding:8px;overflow:hidden;font-size:12px;line-height:1.3}.tile strong{display:block}.tile small{color:#a7d8ce;font-size:10px;overflow:hidden;display:block;white-space:nowrap;text-overflow:ellipsis}h2{font-size:16px;margin:26px 0 10px}.row{display:grid;grid-template-columns:155px 1fr;gap:14px;padding:12px 0;border-bottom:1px solid #293841}.app{font-weight:600;font-size:14px}.detail{font-size:13px;overflow-wrap:anywhere}.why{display:block;color:#9aafbd;margin-top:3px}.badge{font-size:11px;color:#a8c6d7}footer{position:fixed;bottom:0;left:0;right:0;padding:18px 36px;display:flex;justify-content:space-between;align-items:center;background:#14212bee;border-top:1px solid #334752;backdrop-filter:blur(12px)}button{font:inherit;border:1px solid #3d5968;background:#203642;color:#e2edf4;border-radius:8px;padding:10px 16px;cursor:pointer;margin-left:6px}.primary{background:#8bddca;color:#102c2a;border-color:#8bddca;font-weight:650}.note{font-size:12px;color:#a1b6c3}.empty{color:#9bafbb;font-size:13px;padding:8px 0}@media(max-width:760px){body{padding:22px 20px 110px}.row{grid-template-columns:120px 1fr}footer{padding:14px 20px}.stats{gap:6px}.stat{padding:12px}.stat span{display:block}}
</style></head><body><header><div class="brand">▦ DESKGRID</div><span class="version">LAYOUT PREVIEW</span></header><h1>]],esc(title),[[</h1><p class="muted">Review the arrangement below. Everything stays open. Undo restores your previous desk.</p><div class="stats">]]}
  for _,stat in ipairs({{moved,"arranged"},{#(data.minimize or {}),"minimized"},{unchanged,"left unchanged"},{#(data.open or {}),"to open"}})do
    out[#out+1]='<div class="stat"><strong>'..stat[1]..'</strong><span>'..stat[2]..'</span></div>'
  end
  out[#out+1]='</div>'
  for _,screen in ipairs(screens)do
    local f=screen.frame
    out[#out+1]='<div class="display"><div class="screen-label"><span>'..esc(screen.name or "Display")..'</span><span class="muted">'..f.w..' × '..f.h..'</span></div><div class="map" style="aspect-ratio:'..f.w..'/'..f.h..'">'
    for _,item in ipairs(data.keep or {})do
      local t=item.target_frame
      if t and t.x>=f.x-1 and t.y>=f.y-1 and t.x<f.x+f.w and t.y<f.y+f.h then
        out[#out+1]=string.format('<div class="tile" style="left:%.4f%%;top:%.4f%%;width:%.4f%%;height:%.4f%%"><strong>%s</strong><small>%s</small></div>',100*(t.x-f.x)/f.w,100*(t.y-f.y)/f.h,100*t.w/f.w,100*t.h/f.h,esc(item.app_name),esc(item.title))
      end
    end
    out[#out+1]='</div></div>'
  end
  local function rows(label,items,kind)
    out[#out+1]='<h2>'..label..'</h2>'
    if #items==0 then out[#out+1]='<p class="empty">None</p>' end
    for _,item in ipairs(items)do
      out[#out+1]='<div class="row"><div class="app">'..esc(item.app_name or item.label or kind)..'</div><div class="detail">'..esc(item.title or item.label or "Untitled window")..'<span class="why">'..esc(item.reason or (item.unchanged and "Left unchanged" or kind))..'</span></div></div>'
    end
  end
  local arranged,untouched={},{}
  for _,item in ipairs(data.keep or {})do
    local list=item.unchanged and untouched or arranged
    list[#list+1]=item
  end
  rows("Arrange these windows",arranged,"Arranged in the saved position")
  if #untouched>0 then rows("Leave unchanged",untouched,"Left unchanged") end
  rows("Minimize to the Dock",data.minimize or {},"Kept open; recover with Undo or the Dock")
  if #(data.open or {})>0 then rows("Open missing windows",data.open,"Launch this window") end
  if #(data.missing or {})>0 then
    out[#out+1]='<h2>Empty slots (app or window not open)</h2><p>'..esc(table.concat(data.missing,", "))..'</p>'
  end
  out[#out+1]=[[<footer><span class="note">Preview only · no windows changed</span><div><button id="refresh" onclick="send('refresh')">Refresh</button><button id="cancel" onclick="send('cancel')">Cancel</button><button class="primary" id="apply" onclick="send('apply')">Apply layout</button></div></footer><script>function send(action){window.webkit.messageHandlers.deskgrid.postMessage(action)}</script></body></html>]]
  return table.concat(out)
end
return M
