import CoreImage
import CoreVideo
import Foundation
import PhamVisionCore

// Command-line twin of the app, plus tools for tuning detection.
//
//   pv clips <video>      scan a recording and write its LosslessCut project
//   pv scan <video>       raw HUD readings as JSON lines
//   pv plays <scan.jsonl> run detection over a saved scan
//   pv templates <video> --labels ...  rebuild the digit templates
//   pv timeline | info                  tuning helpers

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      pv clips <video> [--before S] [--after S] [--csv 1] [--force 1] [--scan saved.jsonl]
                       [--export DIR] [--reel FILE.mp4] [--min-stars N]
      pv scan <video> [--from S] [--to S] > scan.jsonl
      pv plays <scan.jsonl>
      pv info <video>

    """.utf8))
    exit(2)
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
guard rawArgs.count >= 2 else { usage() }
let command = rawArgs[0]
let url = URL(fileURLWithPath: (rawArgs[1] as NSString).expandingTildeInPath)
let args = Array(rawArgs.dropFirst(2))

func stringOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return (args[i + 1] as NSString).expandingTildeInPath
}

func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return Double(args[i + 1])
}

@Sendable func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

struct TimelineRow: Encodable {
    let t: Double
    let stats: HUDReading?
    let feed: [String]
}

do {
    switch command {
    case "info":
        let info = try await VideoSampler(url: url).info()
        print("duration=\(info.duration) size=\(info.width)x\(info.height) fps=\(info.frameRate)")

    case "timeline":
        let from = option("--from") ?? 0
        let to = option("--to") ?? .infinity
        let sampler = VideoSampler(url: url, samplesPerSecond: option("--fps") ?? 2)
        let reader = HUDReader()
        let noFeed = option("--no-feed") != nil
            var statsTime = 0.0, feedTime = 0.0
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let started = Date()
        var count = 0
        try await sampler.run(from: from) { t, frame in
            guard t <= to else { return false }
            let t0 = Date()
            let stats = reader.readStats(frame)
            let t1 = Date()
            let feed = noFeed ? [] : try reader.readFeed(frame)
            statsTime += t1.timeIntervalSince(t0)
            feedTime += Date().timeIntervalSince(t1)
            let row = TimelineRow(t: (t * 100).rounded() / 100, stats: stats, feed: feed)
            print(String(decoding: try encoder.encode(row), as: UTF8.self))
            count += 1
            return true
        }
        let elapsed = Date().timeIntervalSince(started)
        stderr(String(format: "stats %.1fs, feed %.1fs", statsTime, feedTime))
        stderr(String(format: "%d samples in %.1fs (%.1f samples/s)", count, elapsed, Double(count) / elapsed))

    case "scan":
        // pv scan <video> [--from S] [--to S] > samples.jsonl
        let from = option("--from") ?? 0
        let to = option("--to") ?? .infinity
        let started = Date()
        var scanner = VideoScanner()
        if let w = option("--workers") { scanner.workers = Int(w) }
            let samples = try await scanner.scan(url, range: from...to) { p in
            stderr(String(format: "%.0f%%", p * 100))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for s in samples { print(String(decoding: try encoder.encode(s), as: UTF8.self)) }
        stderr(String(format: "%d samples in %.1fs", samples.count, Date().timeIntervalSince(started)))

    case "clips":
        // pv clips <video> [--before S] [--after S] [--csv 1]
        // The whole pipeline: scan, detect, label, and write the LosslessCut project next to the video.
        let started = Date()
        // MKV and similar are re-packaged into a temporary MP4 first (no re-encoding).
        var source = url
        if Remuxer.needsRemux(url) {
            guard let ffmpeg = Remuxer.findFFmpeg() else { throw Remuxer.RemuxError.ffmpegNotFound }
            stderr("Preparing \(url.pathExtension.uppercased()) with \(ffmpeg.path)")
            source = try await Remuxer.remux(url, ffmpeg: ffmpeg)
        }
        defer { if source != url { try? FileManager.default.removeItem(at: source) } }
        let info = try await VideoSampler(url: source).info()
        let samples: [Sample]
        if let saved = stringOption("--scan") {
            let decoder = JSONDecoder()
            samples = try String(contentsOfFile: saved, encoding: .utf8).split(separator: "\n").map {
                try decoder.decode(Sample.self, from: Data($0.utf8))
            }
        } else {
            samples = try await VideoScanner().scan(source) { p in
                FileHandle.standardError.write(Data(String(format: "\rScanning %3.0f%%", p * 100).utf8))
            }
            stderr("")
        }
        var detection = PlayDetector().analyze(samples)
        GameClock.apply(await GameClock.read(source, at: detection.plays.map(\.time)), to: &detection.plays)
        PlayDetector.splitGamesByClock(&detection.plays, games: &detection.games)
        let plays = detection.plays
        var settings = ClipSettings()
        if let b = option("--before") { settings.before = b }
        if let a = option("--after") { settings.after = a }
        let clips = ClipBuilder.build(plays, settings: settings, videoDuration: info.duration)
        let stars = ClipRating.stars(clips)
        for clip in clips {
            let rating = String(repeating: "★", count: stars[clip.id] ?? 1).padding(toLength: 3, withPad: " ", startingAt: 0)
            let margin = clip.plays.first?.scoreMargin.map { "±\($0)" } ?? "  "
            let clutch = ClipRating.isClutch(clip) ? " CLUTCH" : ""
            print(String(format: "%8.1f %6.1fs %@ %4.1f %@  %@%@", clip.start, clip.duration, rating,
                         ClipRating.excitement(clip), margin, clip.label, clutch))
        }
        stderr("")
        for game in detection.games {
            let totals = game.stats.map { "\($0.found)/\($0.expected) \($0.unit)" }.joined(separator: ", ")
            stderr("\(game.title): \(game.checksOut ? "checks out" : "DOESN'T ADD UP") (\(totals))")
            for gap in game.gaps {
                stderr(String(format: "  gap: %@ %d → %d between %.1f and %.1f", gap.unit, gap.from, gap.to, gap.after, gap.before))
            }
        }
        let project = LosslessCut.projectURL(for: url)
        if FileManager.default.fileExists(atPath: project.path), option("--force") == nil {
            stderr("\(project.lastPathComponent) already exists; pass --force 1 to replace it")
        } else {
            try LosslessCut.project(for: clips, mediaFileName: url.lastPathComponent, stars: stars)
                .write(to: project, options: .atomic)
            stderr("Wrote \(project.path)")
        }
        if option("--csv") != nil {
            let csv = url.deletingPathExtension().appendingPathExtension("clips.csv")
            try LosslessCut.csv(for: clips, stars: stars).write(to: csv, atomically: true, encoding: .utf8)
            stderr("Wrote \(csv.path)")
        }
        let minStars = Int(option("--min-stars") ?? 1)
        let chosen = clips.filter { (stars[$0.id] ?? 1) >= minStars }
        if let folder = stringOption("--export") {
            let names = chosen.enumerated().map {
                ClipExporter.fileName(for: $1, number: $0 + 1, of: chosen.count, stars: stars[$1.id])
            }
            let t0 = Date()
            let files = try await ClipExporter.exportSeparately(chosen, from: source, to: URL(fileURLWithPath: folder), names: names)
            stderr(String(format: "Exported %d clips to %@ in %.1fs", files.count, folder, Date().timeIntervalSince(t0)))
        }
        if let reel = stringOption("--reel") {
            let t0 = Date()
            try await ClipExporter.exportReel(chosen, from: source, to: URL(fileURLWithPath: reel))
            stderr(String(format: "Exported a %d-clip reel to %@ in %.1fs", chosen.count, reel, Date().timeIntervalSince(t0)))
        }
        stderr(String(format: "%d plays, %d clips, %.0f min of video scanned in %.0fs", plays.count, clips.count,
                      info.duration / 60, Date().timeIntervalSince(started)))

    case "templates":
        // pv templates <video> --labels "T:PTS,REB,AST;T:..."  > DigitTemplates.swift
        // Builds the digit templates from frames whose numbers were checked by eye.
        guard let i = args.firstIndex(of: "--labels"), i + 1 < args.count else { usage() }
        let labels = args[i + 1].split(separator: ";").map { entry -> (Double, [Int]) in
            let parts = entry.split(separator: ":")
            return (Double(parts[0])!, parts[1].split(separator: ",").map { Int($0)! })
        }
        let reader = HUDReader()
        var samples: [(digit: Int, glyph: DigitReader.Glyph)] = []
        for (time, values) in labels {
            try await VideoSampler(url: url, samplesPerSecond: 30).run(from: time) { _, frame in
                for (column, value) in values.enumerated() {
                    let digits = String(value).compactMap { Int(String($0)) }
                    let glyphs = reader.glyphs(frame, column: column)
                    guard glyphs.count == digits.count else {
                        stderr("t=\(time) column \(column): found \(glyphs.count) glyphs for \(value), skipped")
                        continue
                    }
                    samples += zip(digits, glyphs).map { ($0, $1) }
                }
                return false
            }
        }
        let templates = DigitReader.buildTemplates(from: samples)
        let counts = Dictionary(grouping: samples, by: \.digit).mapValues(\.count)
        stderr("samples per digit: " + (0...9).map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: " "))
        print(DigitReader.swiftSource(templates), terminator: "")

    case "frame":
        // pv frame <video> --at T --out file.png   saves the frame the scanner sees at T
        guard let at = option("--at"), let i = args.firstIndex(of: "--out"), i + 1 < args.count else { usage() }
        let out = URL(fileURLWithPath: args[i + 1])
        var saved = false
        try await VideoSampler(url: url, samplesPerSecond: 60).run(from: at) { t, frame in
            guard t + 0.001 >= at else { return true }
            let ci = CIImage(cvPixelBuffer: frame)
            try CIContext().writePNGRepresentation(of: ci, to: out, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            stderr(String(format: "frame at %.3f -> %@", t, out.path))
            saved = true
            return false
        }
        if !saved { stderr("no frame at that time") }

    case "clock":
        // pv clock <video> --at T   reads the scoreboard clock at T
        guard let at = option("--at") else { usage() }
        let board = await GameClock.read(url, at: [at])[0]
        let left = board?.leftScore.map(String.init) ?? "-", right = board?.rightScore.map(String.init) ?? "-"
        print("clock: \(board?.clock ?? "-")  score: \(left)–\(right)")

    case "plays":
        // pv plays <samples.jsonl> [--before S] [--after S] [--duration S]
        // Runs detection over a saved scan and prints plays, then clips.
        let decoder = JSONDecoder()
        let samples = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(Sample.self, from: Data($0.utf8))
        }
        let plays = PlayDetector().detect(samples)
        var settings = ClipSettings()
        if let b = option("--before") { settings.before = b }
        if let a = option("--after") { settings.after = a }
        let clips = ClipBuilder.build(plays, settings: settings, videoDuration: option("--duration") ?? (samples.last?.t ?? 0))
        for play in plays {
            print(String(format: "%8.1f  G%d  %@ %@", play.time, play.game, play.kind.rawValue, play.detail))
        }
        stderr("\(plays.count) plays, \(clips.count) clips, \(Int(clips.reduce(0) { $0 + $1.duration }))s of footage")

    default:
        usage()
    }
} catch {
    stderr("pv: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
    exit(1)
}
