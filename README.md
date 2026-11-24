# DeskGrid

DeskGrid is a small macOS window tiler. It snaps your open windows into a
clean grid with one keystroke. You can save a desk layout, load it again
later, and drag one window onto another to make them exchange places.

DeskGrid is a [Hammerspoon](https://www.hammerspoon.org/) Spoon written in Lua.
It is local-first: no account, no network, no telemetry.

<!-- DEMO -->

## Features

- **Snap to grid.** `^⌥⌘0` arranges the open windows into the default grid.
  `^⌥⌘1` runs the smart layout, which ranks the windows and builds a grid for
  the current displays.
- **Save a layout.** `^⌥⌘S` stores the current window positions under a name.
- **Load a layout.** `^⌥⌘L` opens a picker and puts each window back in its
  saved slot. A layout saved on a different display is scaled to fit.
- **Drag to swap.** Drag a window and drop it on another window. The two
  windows exchange position and size. A blue outline shows the target before
  you drop. Hold `Option` to drag normally, or press `Esc` to cancel.
- **Undo.** Every arrangement and every swap stores an Undo checkpoint. Use
  the `▦` menu to undo the last arrangement or the last swap.
- **Preview.** The `▦` menu can preview the default or smart layout before it
  moves anything.

DeskGrid never launches or quits apps. A slot without an open window stays
empty. Windows that do not fit are minimized, never closed.

## Install

1. Install Hammerspoon:

   ```bash
   brew install --cask hammerspoon
   ```

2. Open Hammerspoon and give it the Accessibility permission
   (System Settings → Privacy & Security → Accessibility).

3. Copy the Spoon into your Hammerspoon folder:

   ```bash
   git clone https://github.com/palvimaki/deskgrid.git
   mkdir -p ~/.hammerspoon/Spoons
   cp -R deskgrid/DeskGrid.spoon ~/.hammerspoon/Spoons/
   ```

4. Add the lines from [`examples/init.lua`](examples/init.lua) to
   `~/.hammerspoon/init.lua`, then choose **Reload Config** in the Hammerspoon
   menu.

The `▦` icon appears in the menu bar.

## Shortcuts

| Keys    | Action                    |
|---------|---------------------------|
| `^⌥⌘0`  | Default grid layout       |
| `^⌥⌘1`  | Smart layout              |
| `^⌥⌘S`  | Save the current layout   |
| `^⌥⌘L`  | Load a saved layout       |

You can bind other keys in `bindHotkeys`. Drag-to-swap can be turned off in
the `▦` menu.

## Data and privacy

DeskGrid keeps its files in `~/.hammerspoon`, readable only by you:

- `deskgrid_layouts.json`: saved layouts.
- `deskgrid_config.json`: preferences.
- `deskgrid-state/`: Undo checkpoints.

Saved layouts contain window titles and Finder folder paths. Treat them as
private. See [SECURITY.md](SECURITY.md).

## Customize the default grid

The default grid is defined in `_createDefaultPlan` in
`DeskGrid.spoon/init.lua`. Each `slot(...)` line names an app, a column, a
row and the number of rows in that column. Edit it to fit your own apps, or
save a layout and set it as the default.

## License

MIT. See [LICENSE](LICENSE).
