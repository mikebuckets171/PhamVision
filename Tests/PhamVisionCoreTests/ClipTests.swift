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

@Test func ffmpegProbeParsing() {
    let text = """
    Input #0, matroska,webm, from 'stream.mkv':
      Duration: 05:12:07.48, start: 0.000000, bitrate: 24012 kb/s
      Stream #0:0: Video: hevc (Main), yuv420p(tv, bt709), 2560x1440, 60 fps
      Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp
    """
    let probe = Remuxer.parseProbe(text)
    #expect(probe.videoCodec == "hevc")
    #expect(probe.audioCodec == "aac")
    #expect(abs((probe.duration ?? 0) - 18727.48) < 0.01)
}

@Test func remuxArgumentsCopyStreams() throws {
    let src = URL(fileURLWithPath: "/tmp/a.mkv"), dst = URL(fileURLWithPath: "/tmp/b.mp4")
    let hevc = try Remuxer.arguments(source: src, destination: dst, probe: .init(duration: 10, videoCodec: "hevc", audioCodec: "aac"))
    #expect(hevc.contains("hvc1"))
    #expect(hevc.contains("0:a:0"))
    #expect(!hevc.contains("libx264"))
    // Opus can't go in an MP4 that QuickTime plays, so the copy is silent.
    let opus = try Remuxer.arguments(source: src, destination: dst, probe: .init(duration: 10, videoCodec: "h264", audioCodec: "opus"))
    #expect(!opus.contains("0:a:0"))
    #expect(!opus.contains("hvc1"))
    #expect(throws: Remuxer.RemuxError.unsupportedVideo("vp9")) {
        try Remuxer.arguments(source: src, destination: dst, probe: .init(duration: 10, videoCodec: "vp9", audioCodec: nil))
    }
}

@Test func onlyUnreadableContainersAreRemuxed() {
    #expect(Remuxer.needsRemux(URL(fileURLWithPath: "/x/Stream.MKV")))
    #expect(!Remuxer.needsRemux(URL(fileURLWithPath: "/x/stream.mp4")))
}

private func rated(_ kind: PlayKind, amount: Int = 2, clock: String? = nil, margin: Int? = nil, detail: String = "") -> Clip {
    Clip(id: 0, start: 0, end: 15, plays: [
        Play(id: 1, time: 12, kind: kind, detail: detail, game: 1, clock: clock, amount: amount, scoreMargin: margin),
    ])
}

@Test func lateCloseThreeOutranksEarlyLayup() {
    let early = rated(.points, amount: 2, clock: "1st 4:00", margin: 2)
    let clutch = rated(.points, amount: 3, clock: "4th 0:40", margin: 2)
    #expect(ClipRating.excitement(clutch) > ClipRating.excitement(early) * 2)
    #expect(ClipRating.isClutch(clutch))
    #expect(!ClipRating.isClutch(early))
}

@Test func blowoutIsNotClutch() {
    #expect(!ClipRating.isClutch(rated(.points, amount: 3, clock: "4th 0:40", margin: 25)))
}

@Test func starsSpreadAcrossClips() {
    var clips = (0..<10).map { i in rated(.points, amount: i < 2 ? 3 : 2, clock: i < 2 ? "4th 0:30" : "1st 3:00", margin: 3) }
    for i in clips.indices { clips[i].id = i + 1 }
    let stars = ClipRating.stars(clips)
    #expect(stars[1] == 3 && stars[2] == 3)
    #expect(stars.values.filter { $0 == 3 }.count == 2)
    #expect(stars.values.filter { $0 == 1 }.count == 4)
}

@Test func scoreboardMarginAndClockParsing() {
    #expect(Scoreboard(clock: nil, leftScore: 62, rightScore: 71).margin == 9)
    #expect(Scoreboard(clock: nil, leftScore: 62, rightScore: nil).margin == nil)
    #expect(GameClock.secondsLeft("4th 1:07") == 67)
    #expect(GameClock.secondsLeft("3rd") == nil)
}

@Test func exportFileNamesAreSafeAndOrdered() {
    let clip = Clip(id: 3, start: 0, end: 15, plays: [
        Play(id: 1, time: 12, kind: .points, detail: "+3 PTS (18 → 21)", game: 2, clock: "4th 0:57", amount: 3),
        Play(id: 2, time: 13, kind: .feed, detail: "Steal", game: 2),
    ])
    let name = ClipExporter.fileName(for: clip, number: 3, of: 66, stars: 3)
    #expect(name == "03 G2 4th 0.57 +3 PTS + Steal ★★★")
    #expect(!name.contains(":") && !name.contains("/"))
}

@Test func losslessCutProjectMarksUntickedClips() throws {
    let clips = ClipBuilder.build([play(100), play(300, .assist)], settings: ClipSettings(), videoDuration: 1000)
    let data = try LosslessCut.project(for: clips, mediaFileName: "s.mp4", stars: [1: 3], selected: { $0.id == 1 })
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let segments = try #require(json["cutSegments"] as? [[String: Any]])
    #expect(segments.map { $0["selected"] as? Bool } == [true, false])
    #expect((segments[0]["name"] as? String)?.hasPrefix("★★★ ") == true)
}

@Test func verticalCaptions() {
    let clip = Clip(id: 1, start: 0, end: 15, plays: [
        Play(id: 1, time: 12, kind: .points, detail: "+3 PTS (18 → 21)", game: 1, clock: "4th 0:57", amount: 3),
    ])
    let caption = VerticalExporter.caption(for: clip)
    #expect(caption.title == "+3 PTS")
    #expect(caption.detail == "G1 · 4th 0:57")
    #expect(VerticalExporter.titleSize(for: "+1 AST + Steal + +1 AST") < VerticalExporter.titleSize(for: "+3 PTS"))
}
