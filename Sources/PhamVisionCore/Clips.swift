import Foundation

public struct ClipSettings: Sendable, Codable, Equatable {
    /// Seconds of video kept before the stat changed.
    public var before: Double = 12
    /// Seconds kept after.
    public var after: Double = 3
    /// Back-to-back plays merge into one clip until it would exceed this.
    public var maxMergedLength: Double = 45
    public var kinds: Set<PlayKind> = Set(PlayKind.allCases)

    public init() {}
}

/// A stretch of video to cut, covering one or more plays.
public struct Clip: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var plays: [Play]

    public var duration: Double { end - start }

    /// "G2 3rd 4:43 · Assist +1 AST (9 → 10)"
    public var label: String {
        var parts = ["G\(plays.first?.game ?? 1)"]
        if let clock = plays.first?.clock { parts[0] += " " + clock }
        for play in plays {
            parts.append(play.kind == .feed ? play.detail : "\(play.kind.title) \(play.detail)")
        }
        return parts.joined(separator: " · ")
    }

    /// Every kind of play in the clip, for filtering.
    public var kinds: Set<PlayKind> { Set(plays.map(\.kind)) }
}

public enum ClipBuilder {
    /// Wraps each play in a before/after window and merges windows that overlap.
    public static func build(_ plays: [Play], settings: ClipSettings, videoDuration: Double) -> [Clip] {
        var clips: [Clip] = []
        for play in plays.sorted(by: { $0.time < $1.time }) where settings.kinds.contains(play.kind) {
            let start = max(0, play.time - settings.before)
            let end = min(videoDuration, play.time + settings.after)
            guard end > start else { continue }
            if var last = clips.last, start < last.end, last.plays.first?.game == play.game {
                if end - last.start <= settings.maxMergedLength {
                    last.end = max(last.end, end)
                    last.plays.append(play)
                    clips[clips.count - 1] = last
                    continue
                }
                // Too long to merge: start the new clip where the last one ended
                // so the same seconds never appear twice.
                clips.append(Clip(id: 0, start: min(last.end, play.time - 2), end: end, plays: [play]))
                continue
            }
            clips.append(Clip(id: 0, start: start, end: end, plays: [play]))
        }
        for i in clips.indices { clips[i].id = i + 1 }
        return clips
    }
}
