import Foundation

public enum PlayKind: String, Codable, Sendable, CaseIterable {
    /// Baskets by teammates and opponents, from the scoreboard.
    case points, assist, rebound, feed, others

    public var title: String {
        switch self {
        case .points: return "Points"
        case .assist: return "Assist"
        case .rebound: return "Rebound"
        case .feed: return "Highlight"
        case .others: return "Basket"
        }
    }

    /// Kinds left out unless asked for.
    public static let optIn: Set<PlayKind> = [.others]
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
    /// How much the stat went up: 3 for a three, 1 for an assist or a steal.
    public var amount: Int
    /// Points between the two teams on the scoreboard, when it could be read.
    public var scoreMargin: Int?

    public init(id: Int, time: Double, kind: PlayKind, detail: String, game: Int, clock: String? = nil,
                amount: Int = 1, scoreMargin: Int? = nil) {
        self.id = id
        self.time = time
        self.kind = kind
        self.detail = detail
        self.game = game
        self.clock = clock
        self.amount = amount
        self.scoreMargin = scoreMargin
    }
}

/// How one game's plays add up against its stat line: the accuracy check.
public struct GameSummary: Sendable, Equatable {
    public struct Stat: Sendable, Equatable {
        public var kind: PlayKind
        public var unit: String
        /// The stat when the game (or the recording) started, and when it ended.
        public var first: Int
        public var last: Int
        /// Total of the changes that became plays.
        public var found: Int

        public init(kind: PlayKind, unit: String, first: Int, last: Int, found: Int) {
            self.kind = kind
            self.unit = unit
            self.first = first
            self.last = last
            self.found = found
        }

        /// How much the stat went up while recording.
        public var expected: Int { last - first }
        /// Positive: changes with no play. Negative: more plays than changes.
        public var missing: Int { expected - found }
    }

    /// A rise in a stat that couldn't be turned into a play, usually because
    /// the HUD was hidden for a long time while it happened.
    public struct Gap: Sendable, Equatable {
        public var kind: PlayKind
        public var unit: String
        public var from: Int
        public var to: Int
        /// Last time the old number was on screen, and first time the new one was.
        public var after: Double
        public var before: Double

        public init(kind: PlayKind, unit: String, from: Int, to: Int, after: Double, before: Double) {
            self.kind = kind
            self.unit = unit
            self.from = from
            self.to = to
            self.after = after
            self.before = before
        }
    }

    /// Detector order, 1-based.
    public var index: Int
    /// Game numbers as shown to the user; more than one only when the
    /// scoreboard showed a new game the stat line didn't.
    public var games: [Int]
    public var start: Double
    public var end: Double
    public var stats: [Stat]
    public var gaps: [Gap]

    public var checksOut: Bool { gaps.isEmpty && stats.allSatisfy { $0.missing == 0 } }

    public var title: String {
        guard let first = games.first else { return "Game \(index)" }
        guard let last = games.last, last != first else { return "Game \(first)" }
        return "Games \(first)–\(last)"
    }
}

/// Everything the detector found in a recording.
public struct Detection: Sendable, Equatable {
    public var plays: [Play]
    public var games: [GameSummary]
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
        /// The stat at the start of the current game, and the total of its plays.
        var first: Int?
        var found = 0
        /// Highest value confirmed this game. A rise back up to it after a
        /// misread drop is a correction, not a missed play.
        var peak: Int?
    }

    public func detect(_ samples: [Sample]) -> [Play] {
        analyze(samples).plays
    }

    /// Finds the plays and checks each game's plays against its stat line.
    public func analyze(_ samples: [Sample]) -> Detection {
        var trackers = [
            Tracker(kind: .points, unit: "PTS", maxStep: 4),
            Tracker(kind: .rebound, unit: "REB", maxStep: 2),
            Tracker(kind: .assist, unit: "AST", maxStep: 2),
        ]
        var plays: [Play] = []
        var game = 1
        /// When each game after the first began, for numbering feed plays.
        var gameStarts: [(time: Double, game: Int)] = []
        var sawPlayThisGame = false
        var resetCount = 0
        var resetSince = 0.0
        var summaries: [GameSummary] = []
        var gaps: [GameSummary.Gap] = []
        var gameStart = samples.first?.t ?? 0

        func closeGame(at end: Double) {
            let stats = trackers.compactMap { t -> GameSummary.Stat? in
                guard let first = t.first else { return nil }
                return GameSummary.Stat(kind: t.kind, unit: t.unit, first: first, last: t.value ?? first, found: t.found)
            }
            guard stats.contains(where: { $0.expected != 0 || $0.found != 0 }) || !gaps.isEmpty else { return }
            summaries.append(GameSummary(
                index: summaries.count + 1, games: [game], start: gameStart, end: end, stats: stats, gaps: gaps
            ))
        }

        for sample in samples {
            guard let stats = sample.stats else { continue }
            let readings = [stats.points, stats.rebounds, stats.assists]

            // New game: all three numbers back near zero after a game that had more.
            let known = trackers.compactMap(\.value)
            if let p = readings[0], let r = readings[1], let a = readings[2],
               p + r + a <= newGameMaxTotal, known.count == 3, known.reduce(0, +) > newGameMaxTotal {
                if resetCount == 0 { resetSince = sample.time }
                resetCount += 1
                if resetCount >= resyncConfirmations {
                    let changed = trackers.contains { $0.first != nil && $0.value != $0.first }
                    closeGame(at: resetSince)
                    if sawPlayThisGame || changed {
                        game += 1
                        gameStarts.append((resetSince, game))
                    }
                    sawPlayThisGame = false
                    gaps = []
                    gameStart = resetSince
                    for i in trackers.indices {
                        trackers[i].value = readings[i]
                        trackers[i].first = readings[i]
                        trackers[i].peak = readings[i]
                        trackers[i].found = 0
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
                        if t.first == nil { t.first = read }
                        t.peak = max(t.peak ?? read, read)
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
                        detail: "+\(step) \(t.unit) (\(current) → \(read))", game: game, amount: step
                    ))
                    t.found += step
                    t.peak = max(t.peak ?? read, read)
                    sawPlayThisGame = true
                } else {
                    // A drop or an impossible jump: after enough agreeing reads,
                    // accept it as the new baseline without making a play.
                    guard t.candidateCount >= resyncConfirmations else { continue }
                    let peak = t.peak ?? current
                    if read > peak {
                        gaps.append(GameSummary.Gap(
                            kind: t.kind, unit: t.unit, from: max(current, peak), to: read,
                            after: t.lastSeen, before: t.candidateSince
                        ))
                        t.peak = read
                    }
                }
                t.value = read
                t.candidate = nil
                t.candidateCount = 0
                t.lastSeen = sample.time
            }
        }

        closeGame(at: samples.last?.t ?? gameStart)

        plays.append(contentsOf: feedPlays(samples, gameStarts: gameStarts))
        plays.append(contentsOf: scoreboardPlays(samples, own: plays, gameStarts: gameStarts))
        plays.sort { $0.time < $1.time }
        for i in plays.indices { plays[i].id = i + 1 }
        return Detection(plays: plays, games: summaries)
    }

    /// `splitGamesByClock` for plays and their game summaries together: each
    /// summary takes the game numbers of the plays inside it.
    public static func splitGamesByClock(_ plays: inout [Play], games: inout [GameSummary]) {
        splitGamesByClock(&plays)
        for i in games.indices {
            let numbers = Set(plays.filter { $0.time >= games[i].start && $0.time <= games[i].end }.map(\.game))
            if !numbers.isEmpty { games[i].games = numbers.sorted() }
        }
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

    // MARK: Everyone else's baskets

    /// A team's score going up on the scoreboard.
    struct ScoreChange {
        let time: Double
        let right: Bool
        let from: Int
        let to: Int
        var game = 1
    }

    /// How close in time a scoreboard change and one of the player's own
    /// points or assists must be to count as the same basket.
    static let sameBasketSeconds = 10.0

    /// Baskets by teammates and opponents, read from the scoreboard. The
    /// player's own team is the side whose score rises with their points and
    /// assists; those baskets are already plays, so they're skipped here.
    func scoreboardPlays(_ samples: [Sample], own: [Play], gameStarts: [(time: Double, game: Int)]) -> [Play] {
        var changes = scoreChanges(samples, right: false) + scoreChanges(samples, right: true)
        guard !changes.isEmpty else { return [] }
        for i in changes.indices {
            changes[i].game = gameStarts.last { $0.time <= changes[i].time + 60 }?.game ?? 1
        }

        // Match each of the player's own points and assists to the closest
        // scoreboard change of the right size: that change is the same basket.
        // First pass: either side, to vote on which side is the player's team.
        // Second pass: the player's side only, to pick the changes to skip.
        func match(side: (Int) -> Bool?) -> (matched: Set<Int>, votes: [Int: (left: Int, right: Int)]) {
            var matched = Set<Int>()
            var votes: [Int: (left: Int, right: Int)] = [:]
            for play in own where play.kind == .points || play.kind == .assist {
                let fits = changes.indices.filter { i in
                    let c = changes[i], step = c.to - c.from
                    guard c.game == play.game, !matched.contains(i),
                          abs(c.time - play.time) <= Self.sameBasketSeconds else { return false }
                    if let right = side(play.game), right != c.right { return false }
                    return play.kind == .points ? step == play.amount : step >= 2
                }
                guard let best = fits.min(by: { abs(changes[$0].time - play.time) < abs(changes[$1].time - play.time) })
                else { continue }
                matched.insert(best)
                var v = votes[play.game] ?? (0, 0)
                if changes[best].right { v.right += 1 } else { v.left += 1 }
                votes[play.game] = v
            }
            return (matched, votes)
        }
        let votes = match(side: { _ in nil }).votes
        /// Whether the player's team is on the right, per game; nil if unclear.
        func mySide(_ game: Int) -> Bool? {
            let v = votes[game] ?? (0, 0)
            return v.left == v.right ? nil : v.right > v.left
        }
        let matched = match(side: mySide).matched

        var plays: [Play] = []
        for (index, change) in changes.enumerated() where !matched.contains(index) {
            let step = change.to - change.from
            let mine: Bool? = mySide(change.game).map { $0 == change.right }
            let who: String
            switch mine {
            case true?: who = "Teammate"
            case false?: who = "Opponent"
            case nil: who = change.right ? "Right team" : "Left team"
            }
            plays.append(Play(
                id: 0, time: change.time, kind: .others,
                detail: "\(who) +\(step) (\(change.from) → \(change.to))", game: change.game, amount: step
            ))
        }
        return plays
    }

    /// Rises in one team's score, with the same confirmation rules as the stat line.
    func scoreChanges(_ samples: [Sample], right: Bool) -> [ScoreChange] {
        var t = Tracker(kind: .others, unit: "PTS", maxStep: 4)
        var changes: [ScoreChange] = []
        for sample in samples {
            guard let scores = sample.scores, let read = right ? scores.right : scores.left else { continue }
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
            if step > 0, step <= t.maxStep, t.candidateSince - t.lastSeen <= maxGapSeconds {
                guard t.candidateCount >= confirmations else { continue }
                changes.append(ScoreChange(
                    time: min(t.candidateSince, t.lastSeen + replayLeadSeconds), right: right, from: current, to: read
                ))
            } else {
                // A new game (score back near 0) is accepted quickly. Anything
                // else needs 10 seconds of agreeing reads, so a stray misread
                // such as "99" during an animation can't take over.
                let newGame = read <= 3
                guard t.candidateCount >= (newGame ? resyncConfirmations : 20) else { continue }
            }
            t.value = read
            t.candidate = nil
            t.candidateCount = 0
            t.lastSeen = sample.time
        }
        return changes
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

    private func feedPlays(_ samples: [Sample], gameStarts: [(time: Double, game: Int)]) -> [Play] {
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
                // The stats reset shortly after tip-off, so allow a minute of slack:
                // a feed play just before a reset already belongs to the new game.
                let game = gameStarts.last { $0.time <= time + 60 }?.game ?? 1
                result.append(Play(id: 0, time: time, kind: .feed, detail: phrase.label, game: game))
            }
        }
        return result
    }
}

extension Sample {
    var time: Double { t }
}
