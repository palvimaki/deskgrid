# Security policy

DeskGrid runs inside Hammerspoon with the Accessibility permission. It moves,
resizes and minimizes windows. It does not use the network, it does not send
telemetry, and it never launches or quits apps.

DeskGrid stores its data in `~/.hammerspoon` with owner-only file permissions:

- `deskgrid_layouts.json`: saved layouts (app bundle IDs, window titles, frames,
  Finder folder paths).
- `deskgrid_config.json`: preferences.
- `deskgrid-state/`: Undo checkpoints.

Window titles and folder paths can be private. Do not share these files.

## Report a vulnerability

Please use GitHub private vulnerability reporting
(Security → Report a vulnerability) on this repository. Do not open a public
issue for a security problem.
