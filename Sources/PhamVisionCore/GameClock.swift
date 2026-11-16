@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// What the scoreboard showed at one moment.
public struct Scoreboard: Sendable, Equatable {
    /// Quarter and game clock, e.g. "3rd 4:43".
    public var clock: String?
    public var leftScore: Int?
    public var rightScore: Int?

    public init(clock: String? = nil, leftScore: Int? = nil, rightScore: Int? = nil) {
        self.clock = clock
        self.leftScore = leftScore
        self.rightScore = rightScore
    }

    /// Points between the teams, when both scores were read.
    public var margin: Int? {
        guard let leftScore, let rightScore else { return nil }
        return abs(leftScore - rightScore)
    }
}

/// Reads the scoreboard's quarter, game clock and score at chosen moments, so
/// plays can be labelled "3rd 4:43" and rated. Best effort: modes with a
/// different scoreboard simply get no label.
public enum GameClock {
    /// Returns what the scoreboard showed at each requested time, keyed by index into `times`.
    public static func read(_ url: URL, at times: [Double], layout: HUDLayout = .nba2k27) async -> [Int: Scoreboard] {
        guard !times.isEmpty else { return [:] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // Nearest decodable frame within a quarter second is plenty for a clock.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var boards: [Int: Scoreboard] = [:]
        for (index, time) in times.enumerated() {
            if Task.isCancelled { break }
            let at = CMTime(seconds: time, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: at) else { continue }
            let board = scoreboard(in: image, layout: layout)
            if board.clock != nil || board.margin != nil { boards[index] = board }
        }
        return boards
    }

    /// Fills in each play's clock and score margin.
    public static func apply(_ boards: [Int: Scoreboard], to plays: inout [Play]) {
        for (index, board) in boards where plays.indices.contains(index) {
            plays[index].clock = board.clock
            plays[index].scoreMargin = board.margin
        }
    }

    struct Token {
        let text: String
        /// Centre and height in 1920×1080 reference pixels.
        let midX: CGFloat
        let height: CGFloat
    }

    static func scoreboard(in image: CGImage, layout: HUDLayout) -> Scoreboard {
        let size = CGSize(width: image.width, height: image.height)
        let region = layout.scoreboard
        guard let crop = image.cropping(to: HUDLayout.pixels(region, in: size).integral) else { return Scoreboard() }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return Scoreboard() }
        let tokens = (request.results ?? []).compactMap { obs -> Token? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return Token(text: text, midX: region.minX + box.midX * region.width, height: box.height * region.height)
        }
        var board = Scoreboard(clock: parse(tokens.map(\.text).joined(separator: " ")))
        let scores = scores(in: tokens, clockCenter: layout.clock.midX)
        board.leftScore = scores.left ?? readNumber(image, region: layout.leftScore)
        board.rightScore = scores.right ?? readNumber(image, region: layout.rightScore)
        return board
    }

    /// The two team scores: the tallest whole numbers either side of the clock.
    /// Foul counts ("FLS 0") and the shot clock are much smaller and drop out.
    static func scores(in tokens: [Token], clockCenter: CGFloat) -> (left: Int?, right: Int?) {
        let numbers = tokens.filter { $0.text.allSatisfy(\.isNumber) && (1...3).contains($0.text.count) }
        guard let tallest = numbers.map(\.height).max(), tallest >= 28 else { return (nil, nil) }
        let big = numbers.filter { $0.height >= tallest * 0.75 }
        let left = big.filter { $0.midX < clockCenter - 50 }.max { $0.height < $1.height }
        let right = big.filter { $0.midX > clockCenter + 60 }.max { $0.height < $1.height }
        return (left.flatMap { Int($0.text) }, right.flatMap { Int($0.text) })
    }

    /// Reads one team's score on its own. Text recognition misses lone
    /// coloured digits on the dark scoreboard, so the crop is enlarged,
    /// turned grey, contrast-stretched and inverted to dark-on-light first.
    static func readNumber(_ image: CGImage, region: CGRect) -> Int? {
        let size = CGSize(width: image.width, height: image.height)
        guard let crop = image.cropping(to: HUDLayout.pixels(region, in: size).integral),
              let clean = enhance(crop) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: clean, options: [:]).perform([request])) != nil else { return nil }
        // The tallest whole number is the score; "FLS 0" underneath is small.
        let numbers = (request.results ?? []).compactMap { obs -> (Int, CGFloat)? in
            guard let text = obs.topCandidates(1).first?.string, text.allSatisfy(\.isNumber),
                  (1...3).contains(text.count), let value = Int(text) else { return nil }
            return (value, obs.boundingBox.height)
        }
        guard let best = numbers.max(by: { $0.1 < $1.1 }), best.1 >= 0.4 else { return nil }
        return best.0
    }

    /// 3× larger, greyscale, full contrast, dark text on a light background.
    static func enhance(_ image: CGImage) -> CGImage? {
        let w = image.width * 3, h = image.height * 3
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        var lo = 255, hi = 0
        for i in 0..<(w * h) {
            let v = Int(pixels[i])
            lo = min(lo, v)
            hi = max(hi, v)
        }
        guard hi > lo else { return nil }
        // One team's panel is dark, the other light: only invert a dark one.
        var edge = 0
        for x in 0..<w { edge += Int(pixels[x]) + Int(pixels[(h - 1) * w + x]) }
        let darkBackground = edge / (2 * w) < (lo + hi) / 2
        for i in 0..<(w * h) {
            let stretched = (Int(pixels[i]) - lo) * 255 / (hi - lo)
            pixels[i] = UInt8(darkBackground ? 255 - stretched : stretched)
        }
        return ctx.makeImage()
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

    /// "3rd 4:43" → 283 seconds left in the quarter.
    public static func secondsLeft(_ label: String) -> Double? {
        guard let m = label.firstMatch(of: /(\d{1,2}):(\d{2})/) else { return nil }
        let minutes: Double = Double(m.1) ?? 0
        let seconds: Double = Double(m.2) ?? 0
        return minutes * 60 + seconds
    }
}
