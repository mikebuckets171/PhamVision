import Foundation
import Testing
@testable import PhamVisionCore

private func play(_ t: Double, _ kind: PlayKind = .points, game: Int = 1) -> Play {
    Play(id: 0, time: t, kind: kind, detail: "+2 PTS (0 → 2)", game: game)
}

@Test func clipUsesBeforeAndAfterWindows() {
    let clips = ClipBuilder.build([play(100)], settings: ClipSettings(), videoDuration: 1000)
    #expect(clips.count == 1)
    #expect(clips[0].start == 88)
    #expect(clips[0].end == 103)
}

@Test func overlappingPlaysMerge() {
    let clips = ClipBuilder.build([play(100), play(108, .assist)], settings: ClipSettings(), videoDuration: 1000)
    #expect(clips.count == 1)
    #expect(clips[0].start == 88)
    #expect(clips[0].end == 111)
    #expect(clips[0].plays.count == 2)
}

@Test func mergingStopsAtMaxLengthWithoutRepeatingFootage() {
    let plays = stride(from: 100.0, through: 180.0, by: 10).map { play($0) }
    let clips = ClipBuilder.build(plays, settings: ClipSettings(), videoDuration: 1000)
    #expect(clips.count > 1)
    #expect(clips.allSatisfy { $0.duration <= 45 })
    for (a, b) in zip(clips, clips.dropFirst()) { #expect(b.start >= a.end) }
}

@Test func clipsClampToVideoBounds() {
    let clips = ClipBuilder.build([play(5), play(998)], settings: ClipSettings(), videoDuration: 1000)
    #expect(clips[0].start == 0)
    #expect(clips[1].end == 1000)
}

@Test func kindFilterDropsPlays() {
    var settings = ClipSettings()
    settings.kinds = [.assist]
    let clips = ClipBuilder.build([play(100), play(300, .assist)], settings: settings, videoDuration: 1000)
    #expect(clips.count == 1)
    #expect(clips[0].kinds == [.assist])
}

@Test func losslessCutProjectRoundTrips() throws {
    let clips = ClipBuilder.build([play(100)], settings: ClipSettings(), videoDuration: 1000)
    let data = try LosslessCut.project(for: clips, mediaFileName: "stream.mp4")
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["version"] as? Int == 2)
    #expect(json["mediaFileName"] as? String == "stream.mp4")
    let segments = try #require(json["cutSegments"] as? [[String: Any]])
    #expect(segments.count == 1)
    #expect(segments[0]["start"] as? Double == 88)
    #expect(segments[0]["end"] as? Double == 103)
    #expect(segments[0]["selected"] as? Bool == true)
    #expect(segments[0]["name"] as? String == "G1 · Points +2 PTS (0 → 2)")
}

@Test func csvQuotesLabels() {
    let clips = ClipBuilder.build([play(100)], settings: ClipSettings(), videoDuration: 1000)
    #expect(LosslessCut.csv(for: clips) == "88.0,103.0,\"G1 · Points +2 PTS (0 → 2)\"\n")
}

@Test func gameClockParsing() {
    #expect(GameClock.parse("4:43 3rd 20") == "3rd 4:43")
    #expect(GameClock.parse("38.3 4th 24") == "4th 0:38")
    #expect(GameClock.parse("REC 2:20 1st") == "1st 2:20")
    #expect(GameClock.parse("SEASON 2") == nil)
}

@Test func projectFileSitsNextToVideo() {
    let url = LosslessCut.projectURL(for: URL(fileURLWithPath: "/Users/x/Movies/Stream 1.mp4"))
    #expect(url.path == "/Users/x/Movies/Stream 1-proj.llc")
}
