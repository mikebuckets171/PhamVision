import CoreGraphics
import CoreVideo
import Vision

/// What the HUD showed in one frame. A nil stat means that number couldn't
/// be read cleanly in this frame.
public struct HUDReading: Sendable, Codable, Equatable {
    public var points: Int?
    public var rebounds: Int?
    public var assists: Int?

    public init(points: Int? = nil, rebounds: Int? = nil, assists: Int? = nil) {
        self.points = points
        self.rebounds = rebounds
        self.assists = assists
    }
}

/// The two team scores on the scoreboard; nil where a score couldn't be read.
public struct ScoreReading: Sendable, Codable, Equatable {
    public var left: Int?
    public var right: Int?

    public init(left: Int? = nil, right: Int? = nil) {
        self.left = left
        self.right = right
    }
}

/// Reads the stat strip and the event feed from a frame.
///
/// Stat numbers are read by matching digit shapes (`DigitReader`); the event
/// feed is free text, so it goes through Apple's on-device text recognition.
public final class HUDReader: @unchecked Sendable {
    public let layout: HUDLayout
    public var digits: DigitReader
    public var feedLevel: VNRequestTextRecognitionLevel = .fast
    /// Largest brightness spread the HUD's flat backing shows between the
    /// numbers (measured up to 32 on real footage; gameplay shows far more).
    public var maxGapContrast = 60

    public init(layout: HUDLayout = .nba2k27, digits: DigitReader = DigitReader()) {
        self.layout = layout
        self.digits = digits
    }

    // MARK: Stats

    /// Returns nil when the stat strip isn't on screen (menus, replays,
    /// loading screens).
    public func readStats(_ frame: CVPixelBuffer) -> HUDReading? {
        // The HUD backing is a flat colour. Texture in the gaps between the
        // numbers means gameplay or a menu is showing there instead.
        let gaps = gapStats(frame)
        guard gaps.max - gaps.min <= maxGapContrast else { return nil }

        let values = (0..<3).map { column -> Int? in
            guard let cell = Self.lumaBlock(frame, region: layout.cell(column)) else { return nil }
            return digits.read(cell.bytes, width: cell.width, height: cell.height)?.value
        }
        // Two clean numbers are needed to trust that this is the HUD at all.
        guard values.compactMap({ $0 }).count >= 2 else { return nil }
        return HUDReading(points: values[0], rebounds: values[1], assists: values[2])
    }

    /// The digit glyphs found in one stat column, for building templates.
    public func glyphs(_ frame: CVPixelBuffer, column: Int) -> [DigitReader.Glyph] {
        guard let cell = Self.lumaBlock(frame, region: layout.cell(column)) else { return [] }
        return DigitReader.glyphs(cell.bytes, width: cell.width, height: cell.height)
    }

    /// Brightness statistics of the gaps between the stat numbers, where the
    /// HUD shows only its dark backing.
    public func gapStats(_ frame: CVPixelBuffer) -> (mean: Double, max: Int, min: Int) {
        var sum = 0, count = 0, hi = 0, lo = 255
        for rect in layout.gaps {
            for v in Self.lumaBlock(frame, region: rect)?.bytes ?? [] {
                sum += Int(v); count += 1
                hi = max(hi, Int(v)); lo = min(lo, Int(v))
            }
        }
        return (count > 0 ? Double(sum) / Double(count) : 0, hi, lo)
    }

    // MARK: Scoreboard

    /// Per score: the pixels when it was last read, the previous frame's
    /// pixels, its value, and whether that value came from still pixels.
    /// Text recognition runs only when the score area has changed since the
    /// last read (gradual fades add up) or was still moving then, so a read
    /// taken mid-animation never sticks. Call with frames in order.
    private struct ScoreCell {
        var atRead: [UInt8] = []
        var previous: [UInt8] = []
        var value: Int?
        var settled = false
    }
    private var scoreCells = [ScoreCell(), ScoreCell()]
    /// Measured: a score change moves ~400 pixels past this; video noise, under 10.
    static let scoreThreshold = 24

    public func readScores(_ frame: CVPixelBuffer) -> ScoreReading {
        var values: [Int?] = []
        for (i, region) in [layout.leftScore, layout.rightScore].enumerated() {
            guard let block = Self.lumaBlock(frame, region: region) else {
                values.append(nil)
                continue
            }
            var cell = scoreCells[i]
            // Some team colours are close in brightness to their panel, so
            // score changes need a lower threshold than the stat line.
            let moving = cell.previous.isEmpty || Self.differs(block.bytes, cell.previous, by: Self.scoreThreshold)
            if cell.atRead.isEmpty || !cell.settled || Self.differs(block.bytes, cell.atRead, by: Self.scoreThreshold) {
                cell.value = Self.image(frame, region: region).flatMap(GameClock.readScore(crop:))
                cell.atRead = block.bytes
                cell.settled = !moving
            }
            cell.previous = block.bytes
            scoreCells[i] = cell
            values.append(cell.value)
        }
        return ScoreReading(left: values[0], right: values[1])
    }

    /// True when enough pixels changed by a wide margin to mean new content,
    /// as opposed to video compression shimmer.
    static func differs(_ a: [UInt8], _ b: [UInt8], by threshold: Int = 40) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        let needed = max(4, a.count / 200)
        var count = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > threshold {
            count += 1
            if count >= needed { return true }
        }
        return false
    }

    // MARK: Feed

    /// Returns each line of text currently shown in the event feed.
    public func readFeed(_ frame: CVPixelBuffer) throws -> [String] {
        guard let image = Self.image(frame, region: layout.feed) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = feedLevel
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count >= 3 ? text : nil
        }
    }

    // MARK: Pixels

    /// Copies `region` (reference pixels) out of the frame's luma plane.
    static func lumaBlock(_ frame: CVPixelBuffer, region: CGRect) -> (bytes: [UInt8], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let planar = CVPixelBufferIsPlanar(frame)
        let width = planar ? CVPixelBufferGetWidthOfPlane(frame, 0) : CVPixelBufferGetWidth(frame)
        let height = planar ? CVPixelBufferGetHeightOfPlane(frame, 0) : CVPixelBufferGetHeight(frame)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame) else { return nil }
        let rect = HUDLayout.pixels(region, in: CGSize(width: width, height: height)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let w = Int(rect.width), h = Int(rect.height), x0 = Int(rect.minX), y0 = Int(rect.minY)
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBufferPointer { dst in
            for row in 0..<h {
                (dst.baseAddress! + row * w).update(from: src + (y0 + row) * stride + x0, count: w)
            }
        }
        return (bytes, w, h)
    }

    /// `region` as a grayscale image.
    static func image(_ frame: CVPixelBuffer, region: CGRect) -> CGImage? {
        guard let (bytes, w, h) = lumaBlock(frame, region: region),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
