import Foundation

/// Rates clips so the best ones can be shown first.
///
/// A clip's score adds up what happened in it (a three beats a free throw,
/// a block beats a rebound) and weights it by when it happened: plays in the
/// last two minutes of the 4th quarter or overtime count for more, and more
/// again when the score was close. Stars are given relative to the other
/// clips in the same recording.
public enum ClipRating {
    /// Base value of one play.
    static func value(of play: Play) -> Double {
        switch play.kind {
        case .points:
            switch play.amount {
            case ...1: return 0.6
            case 2: return 2
            default: return Double(play.amount)
            }
        case .assist: return 2
        case .rebound: return 1
        case .feed: return play.detail == "Block" ? 3 : 2.5
        case .others:
            // Someone else's basket: worth less than the player's own.
            let share = play.detail.hasPrefix("Teammate") ? 0.7 : play.detail.hasPrefix("Opponent") ? 0.5 : 0.6
            return Double(play.amount) * share
        }
    }

    /// Late-game weight: up to 2× in the final minute of the 4th or overtime.
    static func lateWeight(of play: Play) -> Double {
        guard let clock = play.clock, let quarter = PlayDetector.quarterIndex(clock), quarter >= 4,
              let left = GameClock.secondsLeft(clock) else { return 1 }
        if left <= 60 { return 2 }
        if left <= 120 { return 1.5 }
        return 1.1
    }

    /// Close-game weight from the score margin, when it was read.
    static func closeWeight(of play: Play) -> Double {
        guard let margin = play.scoreMargin else { return 1 }
        switch margin {
        case ...3: return 1.4
        case ...6: return 1.2
        case 20...: return 0.8
        default: return 1
        }
    }

    public static func excitement(_ clip: Clip) -> Double {
        clip.plays.reduce(0) { $0 + value(of: $1) * lateWeight(of: $1) * closeWeight(of: $1) }
    }

    /// A play in the last two minutes of the 4th or overtime with the game
    /// within six points (or, if the score wasn't read, in the last minute).
    public static func isClutch(_ clip: Clip) -> Bool {
        clip.plays.contains { play in
            guard let clock = play.clock, let quarter = PlayDetector.quarterIndex(clock), quarter >= 4,
                  let left = GameClock.secondsLeft(clock) else { return false }
            if let margin = play.scoreMargin { return left <= 120 && margin <= 6 }
            return left <= 60
        }
    }

    /// 1 to 3 stars per clip: the top fifth get three, the next two fifths
    /// two, the rest one. Clutch clips always get at least two.
    public static func stars(_ clips: [Clip]) -> [Clip.ID: Int] {
        let ranked = clips.map { ($0.id, excitement($0), isClutch($0)) }.sorted { $0.1 > $1.1 }
        let topCut = Int((Double(ranked.count) * 0.2).rounded(.up))
        let midCut = Int((Double(ranked.count) * 0.6).rounded(.up))
        var stars: [Clip.ID: Int] = [:]
        for (rank, entry) in ranked.enumerated() {
            var count = rank < topCut ? 3 : rank < midCut ? 2 : 1
            if entry.2 { count = max(count, 2) }
            stars[entry.0] = count
        }
        return stars
    }
}
