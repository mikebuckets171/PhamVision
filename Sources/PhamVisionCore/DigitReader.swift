import Foundation

/// Reads the HUD's stat numbers by matching each digit against templates of
/// the HUD font.
///
/// General text recognition is built for words and stumbles on lone digits
/// (a "6" read as "9", a "0" not read at all). The HUD draws its numbers in
/// one fixed font on a dark backing, so comparing each digit's shape with a
/// stored example of every digit is both more accurate and far cheaper.
/// Glyphs are resampled to a fixed size first, so 1080p, 1440p and 4K
/// recordings all compare against the same templates.
public struct DigitReader: Sendable {
    public static let glyphWidth = 12
    public static let glyphHeight = 18

    /// Pixels of one digit, normalised to zero mean and unit length.
    public struct Glyph: Sendable {
        public var vector: [Float]
        /// Width over height of the digit's bounding box.
        public var aspect: Float
    }

    public struct Template: Sendable {
        public var digit: Int
        public var vector: [Float]
        public var aspect: Float

        public init(digit: Int, vector: [Float], aspect: Float) {
            self.digit = digit
            self.vector = vector
            self.aspect = aspect
        }
    }

    public var templates: [Template]
    /// Minimum correlation with the best template for a digit to count.
    public var minScore: Float = 0.80
    /// How far ahead of the runner-up the best template must be.
    public var minMargin: Float = 0.04

    public init(templates: [Template] = DigitTemplates.nba2k27) {
        self.templates = templates
    }

    public struct Result: Sendable, Equatable {
        public var value: Int
        /// Lowest per-digit correlation in the number.
        public var score: Float
    }

    /// Reads the number in a grayscale cell, or nil if there isn't a clear one.
    public func read(_ pixels: [UInt8], width: Int, height: Int) -> Result? {
        let glyphs = Self.glyphs(pixels, width: width, height: height)
        guard (1...3).contains(glyphs.count) else { return nil }
        var value = 0
        var worst: Float = 1
        for glyph in glyphs {
            guard let (digit, score) = classify(glyph) else { return nil }
            value = value * 10 + digit
            worst = min(worst, score)
        }
        return Result(value: value, score: worst)
    }

    /// Best-matching digit and its correlation, if it clears the thresholds.
    public func classify(_ glyph: Glyph) -> (Int, Float)? {
        var best: (digit: Int, score: Float) = (-1, -.infinity)
        var second: Float = -.infinity
        for template in templates {
            var score = Self.dot(glyph.vector, template.vector)
            // Stretching to a fixed size hides how narrow a "1" is, so
            // penalise shapes whose proportions don't match.
            if abs(glyph.aspect - template.aspect) > 0.22 { score -= 0.5 }
            if score > best.score {
                if best.digit != template.digit { second = best.score }
                best = (template.digit, score)
            } else if template.digit != best.digit, score > second {
                second = score
            }
        }
        guard best.score >= minScore, best.score - second >= minMargin else { return nil }
        return (best.digit, best.score)
    }

    /// Splits a cell into digit glyphs, left to right.
    public static func glyphs(_ pixels: [UInt8], width: Int, height: Int) -> [Glyph] {
        guard width > 2, height > 2, pixels.count == width * height else { return [] }
        let lo = Int(pixels.min()!), hi = Int(pixels.max()!)
        // Digits are near-white on a dark backing; a dim or flat cell has none.
        guard hi >= 140, hi - lo >= 60 else { return [] }
        let threshold = UInt8(lo + (hi - lo) * 55 / 100)

        func on(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] > threshold }

        // Runs of columns that contain ink are the digits.
        var runs: [(Int, Int)] = []
        var start: Int?
        for x in 0..<width {
            let ink = (0..<height).contains { on(x, $0) }
            if ink, start == nil { start = x }
            if !ink, let s = start { runs.append((s, x - 1)); start = nil }
        }
        if let s = start { runs.append((s, width - 1)) }

        var boxes: [(x0: Int, x1: Int, y0: Int, y1: Int)] = []
        for (x0, x1) in runs {
            var y0 = height, y1 = -1
            for y in 0..<height where (x0...x1).contains(where: { on($0, y) }) {
                y0 = min(y0, y); y1 = max(y1, y)
            }
            if y1 >= y0 { boxes.append((x0, x1, y0, y1)) }
        }
        // Drop specks: real digits are all about as tall as the tallest one.
        let tallest = boxes.map { $0.y1 - $0.y0 + 1 }.max() ?? 0
        guard tallest >= 6 else { return [] }
        boxes = boxes.filter { Double($0.y1 - $0.y0 + 1) >= Double(tallest) * 0.7 }

        return boxes.map { box in
            let w = box.x1 - box.x0 + 1, h = box.y1 - box.y0 + 1
            var vector = resample(pixels, stride: width, x0: box.x0, y0: box.y0, w: w, h: h)
            normalize(&vector)
            return Glyph(vector: vector, aspect: Float(w) / Float(h))
        }
    }

    /// Area-averages a region down (or up) to the glyph size.
    static func resample(_ pixels: [UInt8], stride: Int, x0: Int, y0: Int, w: Int, h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: glyphWidth * glyphHeight)
        for gy in 0..<glyphHeight {
            let sy0 = Float(gy) * Float(h) / Float(glyphHeight)
            let sy1 = Float(gy + 1) * Float(h) / Float(glyphHeight)
            for gx in 0..<glyphWidth {
                let sx0 = Float(gx) * Float(w) / Float(glyphWidth)
                let sx1 = Float(gx + 1) * Float(w) / Float(glyphWidth)
                var sum: Float = 0, area: Float = 0
                var y = Int(sy0)
                while Float(y) < sy1, y < h {
                    let wy = min(Float(y + 1), sy1) - max(Float(y), sy0)
                    var x = Int(sx0)
                    while Float(x) < sx1, x < w {
                        let wx = min(Float(x + 1), sx1) - max(Float(x), sx0)
                        sum += Float(pixels[(y0 + y) * stride + x0 + x]) * wx * wy
                        area += wx * wy
                        x += 1
                    }
                    y += 1
                }
                out[gy * glyphWidth + gx] = area > 0 ? sum / area : 0
            }
        }
        return out
    }

    static func normalize(_ v: inout [Float]) {
        let mean = v.reduce(0, +) / Float(v.count)
        var norm: Float = 0
        for i in v.indices { v[i] -= mean; norm += v[i] * v[i] }
        norm = norm.squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    /// Averages labelled glyphs into one template per digit.
    public static func buildTemplates(from samples: [(digit: Int, glyph: Glyph)]) -> [Template] {
        Dictionary(grouping: samples, by: \.digit).keys.sorted().map { digit in
            let group = samples.filter { $0.digit == digit }
            var vector = [Float](repeating: 0, count: glyphWidth * glyphHeight)
            for sample in group { for i in vector.indices { vector[i] += sample.glyph.vector[i] } }
            normalize(&vector)
            let aspect = group.map(\.glyph.aspect).reduce(0, +) / Float(group.count)
            return Template(digit: digit, vector: vector, aspect: aspect)
        }
    }

    /// Swift source for a template table, used to regenerate DigitTemplates.swift.
    public static func swiftSource(_ templates: [Template], name: String = "nba2k27") -> String {
        var lines = [
            "// Generated by `pv templates`. Do not edit by hand.",
            "// Digit shapes of the NBA 2K27 player HUD, \(glyphWidth)x\(glyphHeight), zero-mean and unit-length.",
            "",
            "public enum DigitTemplates {",
            "    public static let \(name): [DigitReader.Template] = [",
        ]
        for t in templates {
            let values = t.vector.map { String(format: "%.4f", $0) }
            var rows: [String] = []
            for r in 0..<glyphHeight {
                rows.append("            " + values[(r * glyphWidth)..<((r + 1) * glyphWidth)].joined(separator: ", ") + ",")
            }
            lines.append("        .init(digit: \(t.digit), vector: [")
            lines.append(contentsOf: rows)
            lines.append(String(format: "        ], aspect: %.4f),", t.aspect))
        }
        lines.append("    ]")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}
