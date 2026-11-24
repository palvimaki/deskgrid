# Security policy

DeskGrid runs inside Hammerspoon with the Accessibility permission. It moves,
resizes and minimizes windows. It does not use the network, it does not send
telemetry, and it never launches or quits apps.

## What DeskGrid accesses

- **Windows:** app bundle IDs, window titles and frames, through the
  Accessibility API.
- **Mouse events:** an event tap watches mouse down, drag and up to detect a
  window drag for drag-to-swap. It does not change or block events. A
  keyboard tap runs only while you drag with the mouse button held on a
  window, to detect `Esc`. Turn
  drag-to-swap off in the `▦` menu to stop both taps.
- **Finder:** when a Finder window is open (also minimized or on another
  Space) during a save, a load or a
  saved-layout preview, DeskGrid asks Finder for the folder paths of its
  windows through Apple Events (`osascript`). macOS asks you for the
  Automation permission first.
- **Helper commands:** `/bin/ps` (to confirm a window still belongs to the
  same process), `/usr/bin/id`, `/usr/bin/mktemp`, `/bin/chmod` and
  `/usr/bin/osascript`. DeskGrid runs them without a login shell, and no
  window title or layout name is part of a command line.
- **Open:** the `▦` menu item **Open Undo history** opens the DeskGrid state
  folder in Finder with `/usr/bin/open`.

## Files

DeskGrid stores its data in `~/.hammerspoon` with owner-only permissions
(`600` for files, `700` for the state folder):

- `deskgrid_layouts.json`: saved layouts (app bundle IDs, window titles,
  frames, display IDs, Finder folder paths).
- `deskgrid_config.json`: preferences.
- `deskgrid-state/`: Undo checkpoints.

Window titles and folder paths can be private. Do not share these files.
Saved data is JSON only. DeskGrid never runs code from these files.

## Report a vulnerability

Please use GitHub private vulnerability reporting
(Security → Report a vulnerability) on this repository. Do not open a public
issue for a security problem.
