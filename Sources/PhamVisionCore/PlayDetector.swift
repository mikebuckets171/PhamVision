import Foundation

public enum PlayKind: String, Codable, Sendable, CaseIterable {
    case points, assist, rebound, feed

    public var title: String {
        switch self {
        case .points: return "Points"
        case .assist: return "Assist"
        case .rebound: return "Rebound"
        case .feed: return "Highlight"
        }
    }
}

/// A moment worth clipping.
public struct Play: Sendable, Codable, Equatable, Identifiable {
    public var id: Int
    /// Seconds into the video where the stat ticked or the feed line appeared.
    public var time: Double
    public var kind: PlayKind
    /// Short description, e.g. "+3 PTS (18 → 21)".
    public var detail: String
    /// 1-based game number within the recording.
    public var game: Int
    /// Quarter and game clock when it happened, e.g. "3rd 4:43".
    public var clock: String?

    public init(id: Int, time: Double, kind: PlayKind, detail: String, game: Int, clock: String? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.detail = detail
        self.game = game
        self.clock = clock
    }
}

/// Turns raw HUD samples into plays.
///
/// A stat change only counts once the new value has been read on consecutive
/// samples, so a single misread never produces a clip. A new game is spotted
/// when every stat drops back to (nearly) zero, and, once game clocks are
/// known, when the quarter goes backwards (see `splitGamesByClock`).
public struct PlayDetector: Sendable {
    /// Consecutive matching reads needed before a rise counts.
    public var confirmations = 2
    /// Consecutive matching reads needed before a drop or implausible jump is
    /// accepted as the new baseline, or a reset as a new game.
    public var resyncConfirmations = 4
    /// 2K hides the HUD during the replay after a basket, so the new number
    /// often first appears several seconds after the play. A rise is placed
    /// just after the old number was last seen, as long as that was no longer
    /// ago than this; beyond it the play can't be placed and is skipped.
    public var maxGapSeconds = 90.0
    /// How long after the old number was last seen the play is placed.
    public var replayLeadSeconds = 1.0
    /// A full reading whose total is at most this, after a game with more,
    /// marks the start of a new game.
    public var newGameMaxTotal = 2
    /// Feed events that become plays on their own because the stat line
    /// doesn't count them. `needle` is matched after `normalize`.
    public var feedHighlights: [FeedPhrase] = PlayDetector.defaultFeedHighlights
    /// The feed line appears a moment after the play itself.
    public var feedLagSeconds = 1.5

    public struct FeedPhrase: Sendable, Equatable {
        public var needle: String
        public var label: String

        public init(_ label: String) {
            self.label = label
            self.needle = PlayDetector.normalize(label)
        }
    }

    public static let defaultFeedHighlights = [FeedPhrase("Steal"), FeedPhrase("Block")]

    public init() {}

    private struct Tracker {
        let kind: PlayKind
        let unit: String
        let maxStep: Int
        var value: Int?
        var lastSeen = -Double.infinity
        var candidate: Int?
        var candidateCount = 0
        var candidateSince = 0.0
    }

    public func detect(_ samples: [Sample]) -> [Play] {
        var trackers = [
            Tracker(kind: .points, unit: "PTS", maxStep: 4),
            Tracker(kind: .rebound, unit: "REB", maxStep: 2),
            Tracker(kind: .assist, unit: "AST", maxStep: 2),
        ]
        var plays: [Play] = []
        var game = 1
        var sawPlayThisGame = false
        var resetCount = 0

        for sample in samples {
            guard let stats = sample.stats else { continue }
            let readings = [stats.points, stats.rebounds, stats.assists]

            // New game: all three numbers back near zero after a game that had more.
            let known = trackers.compactMap(\.value)
            if let p = readings[0], let r = readings[1], let a = readings[2],
               p + r + a <= newGameMaxTotal, known.count == 3, known.reduce(0, +) > newGameMaxTotal {
                resetCount += 1
                if resetCount >= resyncConfirmations {
                    if sawPlayThisGame { game += 1 }
                    sawPlayThisGame = false
                    for i in trackers.indices {
                        trackers[i].value = readings[i]
                        trackers[i].lastSeen = sample.time
                        trackers[i].candidate = nil
                        trackers[i].candidateCount = 0
                    }
                    resetCount = 0
                }
                continue
            }
            resetCount = 0

            for i in trackers.indices {
                guard let read = readings[i] else { continue }
                var t = trackers[i]
                defer { trackers[i] = t }

                guard let current = t.value else {
                    advance(&t, read, at: sample.time)
                    if t.candidateCount >= confirmations {
                        t.value = read
                        t.candidate = nil
                        t.lastSeen = sample.time
                    }
                    continue
                }
                if read == current {
                    t.candidate = nil
                    t.candidateCount = 0
                    t.lastSeen = sample.time
                    continue
                }
                advance(&t, read, at: sample.time)
                let step = read - current
                let gap = t.candidateSince - t.lastSeen
                if step > 0, step <= t.maxStep, gap <= maxGapSeconds {
                    guard t.candidateCount >= confirmations else { continue }
                    plays.append(Play(
                        id: 0, time: min(t.candidateSince, t.lastSeen + replayLeadSeconds), kind: t.kind,
                        detail: "+\(step) \(t.unit) (\(current) → \(read))", game: game
                    ))
                    sawPlayThisGame = true
                } else {
                    // A drop or an impossible jump: after enough agreeing reads,
                    // accept it as the new baseline without making a play.
                    guard t.candidateCount >= resyncConfirmations else { continue }
                }
                t.value = read
                t.candidate = nil
                t.candidateCount = 0
                t.lastSeen = sample.time
            }
        }

        plays.append(contentsOf: feedPlays(samples, statPlays: plays))
        plays.sort { $0.time < $1.time }
        for i in plays.indices { plays[i].id = i + 1 }
        return plays
    }

    /// Starts a new game wherever the quarter goes backwards between two
    /// plays, for games that ended with no stats to reset (0 PTS, 0 REB,
    /// 0 AST). Call after the plays' clocks are filled in.
    public static func splitGamesByClock(_ plays: inout [Play]) {
        var offset = 0
        var previous: (game: Int, quarter: Int)?
        for i in plays.indices {
            let original = plays[i].game
            let quarter = plays[i].clock.flatMap(Self.quarterIndex)
            if let quarter, let previous, previous.game == original, quarter < previous.quarter {
                offset += 1
            }
            if let quarter { previous = (original, quarter) }
            plays[i].game = original + offset
        }
    }

    /// "3rd 4:43" → 3, "OT 1:02" → 5, "OT2 0:40" → 6.
    static func quarterIndex(_ clock: String) -> Int? {
        let word = clock.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        switch word {
        case "1st": return 1
        case "2nd": return 2
        case "3rd": return 3
        case "4th": return 4
        default:
            guard word.hasPrefix("ot") else { return nil }
            return 4 + (Int(word.dropFirst(2)) ?? 1)
        }
    }

    private func advance(_ t: inout Tracker, _ read: Int, at time: Double) {
        if t.candidate == read {
            t.candidateCount += 1
        } else {
            t.candidate = read
            t.candidateCount = 1
            t.candidateSince = time
        }
    }

    /// Reduces a feed line to the characters fast text recognition gets
    /// right, so "@ Asslst: +2" and "Assist: +2" compare equal: lowercase,
    /// i / l / 1 folded together, 0 folded into o, everything else dropped.
    public static func normalize(_ line: String) -> String {
        var out = ""
        for ch in line.lowercased() {
            switch ch {
            case "i", "l", "1", "|", "!": out.append("l")
            case "0", "o": out.append("o")
            case "a"..."z", "2"..."9": out.append(ch)
            default: continue
            }
        }
        return out
    }

    /// Feed events are shown as "<Event>: +<points>", e.g. "Steal: +2".
    static func feedEvent(_ line: String, in phrases: [FeedPhrase]) -> FeedPhrase? {
        guard line.contains("+") else { return nil }
        let normalized = normalize(line)
        return phrases.first { normalized.contains($0.needle) }
    }

    private func feedPlays(_ samples: [Sample], statPlays: [Play]) -> [Play] {
        guard !feedHighlights.isEmpty else { return [] }
        var result: [Play] = []
        var lastSeen: [String: Double] = [:]
        for sample in samples {
            for line in sample.feed {
                guard let phrase = Self.feedEvent(line, in: feedHighlights) else { continue }
                // A line stays on screen for a few seconds; count it once.
                let fresh = sample.time - (lastSeen[phrase.label] ?? -.infinity) > 5
                lastSeen[phrase.label] = sample.time
                guard fresh else { continue }
                let time = max(0, sample.time - feedLagSeconds)
                let game = statPlays.last { $0.time <= time }?.game ?? 1
                result.append(Play(id: 0, time: time, kind: .feed, detail: phrase.label, game: game))
            }
        }
        return result
    }
}

extension Sample {
    var time: Double { t }
}
