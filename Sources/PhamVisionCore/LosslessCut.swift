import Foundation

/// Writes clip lists in the formats LosslessCut reads.
public enum LosslessCut {
    /// LosslessCut's project file (format version 2, checked against
    /// LosslessCut's `llcProjectV2Schema`). Saved next to the video as
    /// `<video name>-proj.llc`, it loads automatically when the video is opened.
    /// `stars` adds a rating to each segment's name; `selected` decides which
    /// segments LosslessCut exports (all by default).
    public static func project(
        for clips: [Clip], mediaFileName: String,
        stars: [Clip.ID: Int] = [:], selected: (Clip) -> Bool = { _ in true }
    ) throws -> Data {
        struct Segment: Encodable {
            let start: Double
            let end: Double
            let name: String
            let tags: [String: String]
            /// Selected segments are the ones LosslessCut exports.
            let selected: Bool
        }
        struct Project: Encodable {
            let version = 2
            let mediaFileName: String
            let cutSegments: [Segment]
        }
        let segments = clips.map { clip in
            Segment(
                start: round3(clip.start), end: round3(clip.end), name: name(clip, stars: stars[clip.id]),
                tags: [
                    "game": String(clip.plays.first?.game ?? 1),
                    "type": clip.kinds.map(\.rawValue).sorted().joined(separator: "+"),
                ],
                selected: selected(clip)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Project(mediaFileName: mediaFileName, cutSegments: segments))
    }

    public static func projectURL(for video: URL) -> URL {
        video.deletingLastPathComponent()
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + "-proj.llc")
    }

    /// "★★★ G1 4th 0:57 · Points +3 PTS (18 → 21)"
    static func name(_ clip: Clip, stars: Int?) -> String {
        guard let stars else { return clip.label }
        return String(repeating: "★", count: stars) + " " + clip.label
    }

    /// `start,end,label` rows in seconds, for File → Import project → CSV.
    public static func csv(for clips: [Clip], stars: [Clip.ID: Int] = [:]) -> String {
        clips.map { clip in
            let label = name(clip, stars: stars[clip.id]).replacingOccurrences(of: "\"", with: "\"\"")
            return "\(round3(clip.start)),\(round3(clip.end)),\"\(label)\""
        }.joined(separator: "\n") + "\n"
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
