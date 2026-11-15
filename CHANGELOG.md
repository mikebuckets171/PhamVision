# Changelog

## 0.1.0

First release.

- Reads your PTS, REB and AST from the NBA 2K27 player HUD and marks a play every time one goes up.
- Picks up steals and blocks from the event feed, which the stat line doesn't count.
- Labels each play with the game number, quarter and game clock.
- Clips cover 12 seconds before the play and 3 seconds after by default, adjustable in the app; back-to-back plays merge into one clip.
- Opens the recording in LosslessCut with every clip already marked, for review and lossless export.
- Watch any clip in the app: double-click a row or press Space, then use the arrow keys to step through.
- Keeps the Mac awake during a scan, shows progress in the Dock, and sends a notification when it finishes.
- Remembers clip length and filter settings between launches.
- Asks before discarding unsaved clips or quitting mid-scan.
- Plain-language messages for MKV files, unfinished recordings and files that aren't video.
- Also saves the clip list as CSV (⌘S).
- `pv` command-line tool for scanning from Terminal.
