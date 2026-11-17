# Changelog

## 1.2.0

- **Automatic updates.** PhamVision now checks for new versions once a day and shows what's new with an Install Update button. You can also check any time with **PhamVision → Check for Updates…**. Updates install and relaunch in place, without the "Open Anyway" step. This is the last version you need to download by hand.
- Updates are signed, and PhamVision refuses any update that isn't signed with the PhamVision key.

## 1.1.0

- **Export for TikTok.** Turns each ticked clip into a vertical 1080×1920 video with the whole gameplay frame in the middle, a blurred fill behind it and a caption above (e.g. "+3 PTS", "G1 · 4th 0:57"), ready for TikTok, Reels or Shorts.
- **Everyone else's baskets.** PhamVision now follows both team scores on the scoreboard, works out which side is yours, and can list teammates' and opponents' baskets too ("Teammate +2", "Opponent +3"). Turn on **Others** above the list to include them; it's off by default.
- **Wrong file?** The scanning screen now has **Choose a Different Recording…** and **Cancel Scan** (Esc).
- Quitting during a scan or export now stops the background work cleanly before the app closes.
- The single highlight reel moved to the **More** menu.

## 1.0.0

The final release.

- **Accuracy check.** After each game, PhamVision compares the plays it found with how much your stat line went up, and lists any stat that rose without becoming a clip, with a Watch button for that stretch.
- **Best clips first.** Every clip gets one to three stars, and late, close-game plays get a CLUTCH tag. Show the list in recording order or best first, and tick only ★★★ or ★★-and-up clips in one click.
- **Export from PhamVision.** Save each ticked clip as its own MP4, or join them into one highlight reel, without re-encoding. LosslessCut is now optional (still needed to read MKV).
- Tick or untick individual clips. Unticked clips are left out of exports and the CSV, and arrive unselected in LosslessCut.
- The scoreboard's score is read alongside the clock, for the close-game rating.
- `pv clips` prints ratings and the accuracy check, and can export with `--export`, `--reel` and `--min-stars`.

## 0.2.1

- Fixed a crash right after "Review in LosslessCut" opened LosslessCut. The clips were saved and LosslessCut opened fine, but PhamVision then quit unexpectedly.
- Fixed the same kind of crash that could happen when a scan finished while PhamVision was in the background and macOS checked whether it may show a notification.
- Releases are now built with the newer Swift that PhamVision is tested with.

## 0.2.0

- MKV recordings can be scanned directly, along with FLV and TS. PhamVision makes a temporary MP4 copy using the ffmpeg inside LosslessCut (no re-encoding) and removes it afterwards. LosslessCut still opens your original file.
- Steals and blocks at the start of a game are now numbered with that game instead of the previous one.
- Builds on Xcode 16 as well as newer toolchains.

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
