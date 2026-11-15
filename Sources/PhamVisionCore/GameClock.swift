@preconcurrency import AVFoundation
import Foundation
import CoreGraphics
import Vision

/// Reads the scoreboard's quarter and game clock at chosen moments, so plays
/// can be labelled "3rd 4:43". Best effort: modes with a different scoreboard
/// simply get no label.
public enum GameClock {
    /// Returns a label per requested time, keyed by index into `times`.
    public static func read(_ url: URL, at times: [Double], layout: HUDLayout = .nba2k27) async -> [Int: String] {
        guard !times.isEmpty else { return [:] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // Nearest decodable frame within a quarter second is plenty for a clock.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var labels: [Int: String] = [:]
        for (index, time) in times.enumerated() {
            if Task.isCancelled { break }
            let at = CMTime(seconds: time, preferredTimescale: 600)
            guard let (image, actual) = try? await generator.image(at: at) else { continue }
            if ProcessInfo.processInfo.environment["PV_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "clock: asked %.2f got %.2f\n", time, actual.seconds).utf8))
            }
            guard let label = label(in: image, layout: layout) else { continue }
            labels[index] = label
        }
        return labels
    }

    static func label(in image: CGImage, layout: HUDLayout) -> String? {
        let rect = HUDLayout.pixels(layout.clock, in: CGSize(width: image.width, height: image.height)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return parse(text)
    }

    /// "4:43 3rd 20" → "3rd 4:43"; "38.3 4th" → "4th 0:38"
    static func parse(_ text: String) -> String? {
        let quarter = text.firstMatch(of: /(?i)\b(1st|2nd|3rd|4th|OT\d?)\b/).map { String($0.1).lowercased() }
        var clock: String?
        if let m = text.firstMatch(of: /\b(\d{1,2}):(\d{2})\b/) {
            clock = "\(m.1):\(m.2)"
        } else if let m = text.firstMatch(of: /\b(\d{1,2})\.\d\b/) {
            // Under a minute the scoreboard shows seconds and tenths.
            clock = String(format: "0:%02d", Int(m.1) ?? 0)
        }
        guard let clock else { return nil }
        guard let quarter else { return clock }
        return "\(quarter.hasPrefix("ot") ? quarter.uppercased() : quarter) \(clock)"
    }
}
