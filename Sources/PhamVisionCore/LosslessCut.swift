import Foundation

/// Writes clip lists in the formats LosslessCut reads.
public enum LosslessCut {
    /// LosslessCut's project file (format version 2, checked against
    /// LosslessCut's `llcProjectV2Schema`). Saved next to the video as
    /// `<video name>-proj.llc`, it loads automatically when the video is opened.
    public static func project(for clips: [Clip], mediaFileName: String) throws -> Data {
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
                start: round3(clip.start), end: round3(clip.end), name: clip.label,
                tags: [
                    "game": String(clip.plays.first?.game ?? 1),
                    "type": clip.kinds.map(\.rawValue).sorted().joined(separator: "+"),
                ],
                selected: true
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

    /// `start,end,label` rows in seconds, for File → Import project → CSV.
    public static func csv(for clips: [Clip]) -> String {
        clips.map { clip in
            let label = clip.label.replacingOccurrences(of: "\"", with: "\"\"")
            return "\(round3(clip.start)),\(round3(clip.end)),\"\(label)\""
        }.joined(separator: "\n") + "\n"
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}
