<p align="center">
  <img src="docs/banner.jpg" alt="PhamVision: every bucket, dime and board from your stream, found and clipped for you" width="100%">
</p>

<h1 align="center">PhamVision</h1>

<p align="center">
  Drop in a 5-hour NBA 2K recording. Get back every play, rated, checked and ready to export, in minutes.
</p>

<p align="center">
  <a href="https://github.com/mikebuckets171/PhamVision/actions/workflows/ci.yml"><img src="https://github.com/mikebuckets171/PhamVision/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/mikebuckets171/PhamVision/releases/latest"><img src="https://img.shields.io/github/v/release/mikebuckets171/PhamVision?color=2EE6B6&label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT licence"></a>
</p>

<p align="center">
  <img src="docs/screenshot.png" alt="PhamVision showing rated clips, an accuracy check and export buttons for a recording" width="820">
</p>

---

## Why

Scrubbing through hours of 2K footage to find your best plays is miserable. The trick streamers use is to watch the stat line in the top-right corner: when your assists go from 17 to 18, something worth clipping just happened.

PhamVision does that watching for you. It reads your **PTS, REB and AST** off the HUD for the whole recording, marks every moment one of them goes up, rates each clip, checks nothing was missed, and exports the ones you tick at full quality.

Tools that clip on loud audio fire on every crowd roar and miss the quiet dimes. PhamVision clips on what actually happened in the game.

## What it does

- **Finds your plays from the stat line.** Every time your points, rebounds or assists tick up, that's a play.
- **Catches steals and blocks** from the event feed under the HUD, since the stat line doesn't count them.
- **Checks its own work.** After each game, PhamVision adds up the plays it found and compares them with how much your stat line went up. If 2 points never became a clip, it says so and lets you watch the stretch where they happened.
- **Best clips first.** Every clip gets one to three stars. Threes beat free throws, blocks beat rebounds, and plays in the last two minutes of a close 4th quarter count for the most. Those get a **CLUTCH** tag.
- **Exports in one click.** Save each ticked clip as its own MP4, or join them into one highlight reel. Nothing is re-encoded, so it takes seconds and the quality is exactly the original.
- **Ready for TikTok.** **Export for TikTok…** turns each ticked clip into a vertical 1080×1920 video: the whole gameplay frame in the middle, a blurred fill behind it and a caption like "+3 PTS · G1 · 4th 0:57" above. About 6 seconds per clip.
- **Everyone's highlights, when you want them.** PhamVision also follows both team scores, works out which side is yours, and can add teammates' and opponents' baskets ("Teammate +2", "Opponent +3"). Turn on **Others** above the list; it's off by default.
- **Labels everything:** game number, quarter and game clock, and what happened, e.g. `03 G1 4th 0.57 +3 PTS ★★★.mp4`.
- **Watch any clip right in the app.** Double-click a row (or press Space) to play just that clip, then step through the rest with the arrow keys.
- **Clips you can adjust.** 12 seconds before the play and 3 after by default. Back-to-back plays merge into one clip instead of duplicating footage.
- **Built for long streams.** Keeps your Mac awake while it scans, shows progress in the Dock, and notifies you when it's done.
- **Runs on your Mac.** Nothing is uploaded anywhere. It works offline.

## Download

1. Download **PhamVision.zip** from the [latest release](https://github.com/mikebuckets171/PhamVision/releases/latest) and unzip it.
2. Move **PhamVision.app** to Applications.
3. *Optional:* install [LosslessCut](https://github.com/mifi/lossless-cut/releases/latest) (free). PhamVision needs it only to read **MKV** recordings, and you can use it to fine-tune clips by hand.

> [!NOTE]
> PhamVision isn't notarised by Apple, so the first time you open it macOS will say it can't verify the developer. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the PhamVision message. You only need to do this once.

## How to use it

1. **Record your session** as usual. **MP4, MOV and MKV** all work. For MKV, PhamVision makes a temporary MP4 copy while it scans (no re-encoding, so it's quick and lossless) and deletes it afterwards. That needs LosslessCut installed and free disk space about the size of the recording.
2. **Drop the recording** onto the PhamVision window, or onto its Dock icon.
3. **Wait a few minutes.** On an M5 Pro, an 89-minute recording takes about 2½ minutes. A 5-hour stream takes roughly 10–20 minutes, depending on your Mac.
4. **Check the list.** The accuracy check under the file name tells you whether every game added up. Switch the order to **Best first**, use **Tick** to keep only ★★★ clips, or untick any you don't want. Double-click a clip to watch it.
5. **Click Export Clips…** to save each ticked clip as its own MP4 in a new folder, or **Export for TikTok…** for vertical videos with captions. A single highlight reel is under **More**.

Picked the wrong recording? Click **Choose a Different Recording…** or **Cancel Scan** (Esc) while it scans.

## How it works

```text
recording.mp4
   │  decoded by the Mac's media engine, 2 frames per second
   ▼
stat line ──► digit matching ──────► PTS 18 → 21 at 24:33
event feed ─► text recognition ────► "Steal: +2" at 17:51
scoreboard ─► text recognition ────► 4th 0:57, 62–71
   │
   ▼
plays ──► clips (12 s before, 3 s after, merged) ──► stars + CLUTCH
   │                                                    │
   └──► accuracy check per game                          ▼
                                     MP4 clips · highlight reel · LosslessCut project
```

- **Reading the numbers.** The HUD draws its numbers in one fixed font on a dark backing, so PhamVision matches each digit's shape against templates of that font instead of using general text recognition. Apple's text recognizer, by comparison, regularly read a 6 as a 9 and skipped lone zeros.
- **Ignoring noise.** A change only counts once it's been read on consecutive frames, so a single bad frame never becomes a clip. When 2K hides the HUD for a replay after a basket, the play is placed at the moment the HUD disappeared, which is when the shot went in.
- **Checking the totals.** For each game, the plays' gains are added up and compared with the stat line's first and last values. A stat that rose while the HUD was hidden for too long to place the play is listed as a gap with its time range.
- **Rating clips.** Each play has a base value (3 for a three, 2 for an assist, 3 for a block). It's weighted up late in the 4th quarter or overtime, up again when the scoreboard shows a close game, and down in blowouts. Stars are relative to the other clips in the same recording.
- **Exporting.** Clips are copied out of the original file with macOS's own video tools, without re-encoding. Each export was checked frame by frame against the recording and is pixel-identical.
- **Everyone else's baskets.** Both team scores are read alongside the stat line, but only re-read when the score area changes, so it adds almost nothing to the scan. The player's team is the side whose score rises with their own points and assists; those baskets are already clips, so only the rest are added.
- **Vertical videos.** Built with Core Image on the Mac's GPU and re-encoded as H.264, since a new frame layout can't be made without re-encoding.
- **Splitting games.** A new game starts when all your stats reset to zero, or when the quarter on the scoreboard goes backwards.
- **Reading MKV.** macOS can't open MKV, so PhamVision borrows the ffmpeg that ships inside LosslessCut to copy the video into a temporary MP4, then scans and exports from that.

### Tested on

Two Rec sessions recorded at 1080p60, checked against the HUD at the end of every game:

| | Session 1 (89 min) | Session 2 (69 min) |
|---|---|---|
| Games found | 3 of 3 | 2 of 2 |
| Accuracy check | all 3 games add up (21/0/14, 31/2/10, 35/1/8) | both games add up (14/1/2, 6/0/0) |
| Steals and blocks from the feed | 5 | 3 |
| Time to scan, M5 Pro | 142 s | 156 s |
| Exported clips | 14 ★★★ clips in 1 s, frame-identical to the recording | 14 clips from inside the app |
| Others (teammates, opponents) | team side found in all 3 games; 90–96% of opponents' points | team side found in both games; 93% of opponents' points |

The digit templates were built from the first session only, so the second session is unseen footage.

## Supported

| | |
|---|---|
| Game | NBA 2K27, default player HUD position |
| Modes | Tested in The Rec. Other modes that show the same player HUD and scoreboard should work |
| Resolutions | 720p to 4K, any 16:9. Tested on a native 1080p recording, plus the same footage rescaled to 720p, 1440p and 4K, which found identical plays |
| Files | MP4, MOV, M4V directly. MKV, FLV and TS through a temporary copy, which needs LosslessCut (or Homebrew ffmpeg) installed. Video must be H.264 or HEVC |
| Macs | macOS 14 Sonoma or later, Apple Silicon or Intel |

## Known limits

- Only The Rec has been tested. If another mode puts the HUD or scoreboard somewhere else, PhamVision won't find the stat line there.
- Teammates' and opponents' baskets come from the scoreboard, so other highlights (their steals, blocks, rebounds) aren't found, and a basket scored while the scoreboard is hidden can be missed (in testing, about 1 in 10 of the opponents' points). Teammate baskets you assisted are already your assist clips, so they aren't listed twice.
- The score is occasionally unreadable early in a game (a lone digit during an animation). Those clips just don't get a close-game bonus; late-game scores read reliably.
- Exported clips start exactly on time in QuickTime and most players. Because nothing is re-encoded, some apps that ignore MP4 edit lists may show a fraction of a second extra at the start.
- The app isn't notarised, so macOS asks once before opening it.

## Command line

PhamVision also comes as a command-line tool, `pv`, for batch jobs or scripting:

```bash
swift build -c release
.build/release/pv clips ~/Movies/stream.mp4 --min-stars 3 --export ~/Movies/best --tiktok ~/Movies/tiktok
```

`pv clips` scans a recording, prints every clip with its rating and the accuracy check, writes a LosslessCut project next to it, and with `--export`, `--reel` or `--tiktok` saves the clips. Add `--everyone 1` to include teammates' and opponents' baskets. Run `.build/release/pv` with no arguments to see the other commands.

## Building from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/mikebuckets171/PhamVision.git
cd PhamVision
swift test
scripts/package.sh 1.1.0
open dist/PhamVision.app
```

`scripts/package.sh` builds a universal app (Apple Silicon and Intel) into `dist/`.

### Project layout

| Path | What's there |
|---|---|
| `Sources/PhamVisionCore/VideoSampler.swift` | Decodes the recording in order and hands out frames |
| `Sources/PhamVisionCore/DigitReader.swift` | Splits a stat cell into digits and matches them against the font |
| `Sources/PhamVisionCore/HUDReader.swift` | Finds the stat line and event feed in a frame |
| `Sources/PhamVisionCore/VideoScanner.swift` | Reads the whole recording in parallel chunks |
| `Sources/PhamVisionCore/PlayDetector.swift` | Turns readings into plays and games, and checks each game's totals |
| `Sources/PhamVisionCore/GameClock.swift` | Reads the scoreboard's quarter, clock and score |
| `Sources/PhamVisionCore/ClipRating.swift` | Stars and the clutch tag |
| `Sources/PhamVisionCore/Clips.swift` | Builds and merges clip windows |
| `Sources/PhamVisionCore/ClipExporter.swift` | Saves clips and reels without re-encoding |
| `Sources/PhamVisionCore/VerticalExporter.swift` | Vertical TikTok videos with captions |
| `Sources/PhamVisionCore/Remuxer.swift` | Makes MKV readable through LosslessCut's ffmpeg |
| `Sources/PhamVisionCore/LosslessCut.swift` | Writes the LosslessCut project and CSV |
| `Sources/PhamVision/` | The Mac app |
| `Sources/pv/` | The command-line tool |

If 2K changes its HUD font in a future game, regenerate the digit templates from a few frames you've checked by eye:

```bash
.build/release/pv templates recording.mp4 --labels "300:0,0,2;1500:21,0,14;4880:30,1,6" > Sources/PhamVisionCore/DigitTemplates.swift
```

Each label is `seconds:PTS,REB,AST`. Between them, the frames need to cover every digit from 0 to 9.

## Credits

- [LosslessCut](https://github.com/mifi/lossless-cut) by Mikael Finstad: its bundled ffmpeg is how PhamVision reads MKV, and it's there for fine-tuning clips by hand.
- Built for and named after **onlyphams**, who came up with the stat-line trick.

## Disclaimer

PhamVision is an independent fan-made tool. It isn't affiliated with or endorsed by 2K, Take-Two Interactive, Visual Concepts or the NBA. NBA 2K is a trademark of its owners. PhamVision only reads video files on your own computer and never connects to any game or online service.

## Licence

[MIT](LICENSE)
