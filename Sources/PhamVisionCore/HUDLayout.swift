import CoreGraphics

/// Screen regions of the NBA 2K27 player HUD, in 1920×1080 reference pixels
/// (top-left origin). Scaled to the real video size at runtime, which holds
/// because 2K scales its HUD with the output resolution.
public struct HUDLayout: Sendable, Codable, Equatable {
    /// Horizontal centres of the PTS, REB and AST numbers.
    public var columnCenters: [CGFloat]
    /// Vertical band the numbers sit in, between the tick marks above and
    /// the labels below.
    public var numberBand: ClosedRange<CGFloat>
    /// Half the width of a number cell; wide enough for two digits without
    /// reaching the next column.
    public var cellHalfWidth: CGFloat
    /// Empty areas between the numbers that show only the HUD's dark backing.
    public var gaps: [CGRect]
    /// Where the event feed ("Steal: +2", "Made Shot: +1") appears.
    public var feed: CGRect
    /// The scoreboard's game clock and quarter (Rec / Pro-Am layout).
    public var clock: CGRect

    public static let reference = CGSize(width: 1920, height: 1080)

    public static let nba2k27 = HUDLayout(
        columnCenters: [1689, 1742, 1796],
        numberBand: 43...67,
        cellHalfWidth: 22,
        gaps: [
            CGRect(x: 1710, y: 44, width: 12, height: 20),
            CGRect(x: 1762, y: 44, width: 14, height: 20),
        ],
        feed: CGRect(x: 1240, y: 96, width: 680, height: 70),
        clock: CGRect(x: 550, y: 985, width: 115, height: 70)
    )

    public init(columnCenters: [CGFloat], numberBand: ClosedRange<CGFloat>, cellHalfWidth: CGFloat,
                gaps: [CGRect], feed: CGRect, clock: CGRect) {
        self.columnCenters = columnCenters
        self.numberBand = numberBand
        self.cellHalfWidth = cellHalfWidth
        self.gaps = gaps
        self.feed = feed
        self.clock = clock
    }

    /// The number cell of column 0 (PTS), 1 (REB) or 2 (AST).
    public func cell(_ column: Int) -> CGRect {
        CGRect(x: columnCenters[column] - cellHalfWidth, y: numberBand.lowerBound,
               width: cellHalfWidth * 2, height: numberBand.upperBound - numberBand.lowerBound)
    }

    /// Converts a reference rect into pixel coordinates of a frame of `size`.
    static func pixels(_ rect: CGRect, in size: CGSize) -> CGRect {
        let sx = size.width / reference.width
        let sy = size.height / reference.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
    }
}
