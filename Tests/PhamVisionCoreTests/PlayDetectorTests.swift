import Testing
@testable import PhamVisionCore

/// Builds samples every 0.5 s from (points, rebounds, assists) tuples; nil = HUD hidden.
private func timeline(_ rows: [(Int?, Int?, Int?)?], start: Double = 0) -> [Sample] {
    rows.enumerated().map { i, row in
        Sample(t: start + Double(i) * 0.5, stats: row.map { HUDReading(points: $0.0, rebounds: $0.1, assists: $0.2) })
    }
}

private func hold(_ p: Int?, _ r: Int?, _ a: Int?, _ n: Int) -> [(Int?, Int?, Int?)?] {
    Array(repeating: (p, r, a), count: n)
}

@Test func risingStatBecomesPlayAtFirstSighting() {
    let samples = timeline(hold(0, 0, 0, 4) + hold(2, 0, 0, 4))
    let plays = PlayDetector().detect(samples)
    #expect(plays.count == 1)
    #expect(plays[0].kind == .points)
    #expect(plays[0].time == 2.0)
    #expect(plays[0].detail == "+2 PTS (0 → 2)")
}

@Test func singleMisreadIsIgnored() {
    let samples = timeline(hold(13, 0, 9, 4) + hold(18, 0, 9, 1) + hold(13, 0, 9, 4))
    #expect(PlayDetector().detect(samples).isEmpty)
}

@Test func unreadableCellsDoNotBreakConfirmation() {
    let samples = timeline(hold(4, 0, 2, 3) + hold(4, nil, 2, 2) + hold(4, 1, 2, 1) + hold(4, nil, 2, 1) + hold(4, 1, 2, 2))
    let plays = PlayDetector().detect(samples)
    #expect(plays.map(\.kind) == [.rebound])
}

@Test func statsResettingToZeroStartsNewGame() {
    let samples = timeline(hold(0, 0, 0, 4) + hold(3, 0, 0, 200) + hold(0, 0, 0, 6) + hold(0, 0, 1, 4))
    let plays = PlayDetector().detect(samples)
    #expect(plays.map(\.kind) == [.points, .assist])
    #expect(plays.map(\.game) == [1, 2])
}

@Test func oneStatMisreadAsLowerIsNotANewGame() {
    let samples = timeline(hold(13, 0, 9, 10) + hold(5, 0, 9, 8) + hold(13, 0, 9, 10) + hold(13, 0, 10, 4))
    let plays = PlayDetector().detect(samples)
    #expect(plays.allSatisfy { $0.game == 1 })
}

@Test func implausibleJumpResyncsSilently() {
    let samples = timeline(hold(5, 1, 1, 4) + hold(19, 1, 1, 8))
    #expect(PlayDetector().detect(samples).isEmpty)
}

@Test func riseAfterReplayIsPlacedWhenHUDDisappeared() {
    // HUD hidden for 10 s (a replay) while the points went up.
    let hidden: [(Int?, Int?, Int?)?] = Array(repeating: nil, count: 20)
    let samples = timeline(hold(5, 1, 1, 4) + hidden + hold(7, 1, 1, 4))
    let plays = PlayDetector().detect(samples)
    #expect(plays.count == 1)
    #expect(plays[0].time == 2.5)  // last seen at 1.5 s, plus one second
}

@Test func riseAfterVeryLongGapIsNotPlaced() {
    let hidden: [(Int?, Int?, Int?)?] = Array(repeating: nil, count: 400)
    let samples = timeline(hold(5, 1, 1, 4) + hidden + hold(7, 1, 1, 4))
    #expect(PlayDetector().detect(samples).isEmpty)
}

@Test func quarterGoingBackwardsSplitsGames() {
    var plays = [
        Play(id: 1, time: 10, kind: .points, detail: "", game: 1, clock: "3rd 2:00"),
        Play(id: 2, time: 20, kind: .points, detail: "", game: 1, clock: "4th 0:30"),
        Play(id: 3, time: 900, kind: .assist, detail: "", game: 1, clock: "1st 4:10"),
        Play(id: 4, time: 950, kind: .assist, detail: "", game: 1, clock: nil),
        Play(id: 5, time: 990, kind: .points, detail: "", game: 2, clock: "1st 3:00"),
    ]
    PlayDetector.splitGamesByClock(&plays)
    #expect(plays.map(\.game) == [1, 1, 2, 2, 3])
}

@Test func simultaneousStatsGiveSeparatePlays() {
    let samples = timeline(hold(5, 1, 1, 4) + hold(7, 2, 1, 4))
    #expect(Set(PlayDetector().detect(samples).map(\.kind)) == [.points, .rebound])
}


@Test func feedNormalisationSurvivesFastRecognitionErrors() {
    #expect(PlayDetector.normalize("@ Asslst: +2•") == PlayDetector.normalize("Assist: +2"))
    #expect(PlayDetector.normalize("Stea1: +2 C").contains(PlayDetector.normalize("Steal")))
}

@Test func stealInFeedBecomesOneHighlight() {
    var samples = timeline(hold(4, 1, 2, 20))
    for i in 8...13 { samples[i].feed = ["* Interceptor", "Stea1: +2"] }
    let plays = PlayDetector().detect(samples)
    #expect(plays.count == 1)
    #expect(plays[0].kind == .feed)
    #expect(plays[0].detail == "Steal")
    #expect(plays[0].time == 2.5)
}

@Test func badgeNamesInFeedAreNotPlays() {
    var samples = timeline(hold(4, 1, 2, 12))
    samples[5].feed = ["Shot Blocker", "Handles for Days", "Good Pass"]
    #expect(PlayDetector().detect(samples).isEmpty)
}
