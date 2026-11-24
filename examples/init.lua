-- Example ~/.hammerspoon/init.lua for DeskGrid.
hs.loadSpoon("DeskGrid")
spoon.DeskGrid:start()
spoon.DeskGrid:bindHotkeys({
  default = { {"ctrl", "alt", "cmd"}, "0" },
  smart   = { {"ctrl", "alt", "cmd"}, "1" },
  save    = { {"ctrl", "alt", "cmd"}, "s" },
  list    = { {"ctrl", "alt", "cmd"}, "l" },
})
