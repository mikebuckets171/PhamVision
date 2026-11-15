import Foundation

/// One look at the HUD at a moment in the video.
public struct Sample: Sendable, Codable, Equatable {
    public var t: Double
    /// nil when the stat strip wasn't on screen.
    public var stats: HUDReading?
    public var feed: [String]

    public init(t: Double, stats: HUDReading?, feed: [String] = []) {
        self.t = t
        self.stats = stats
        self.feed = feed
    }
}

/// Reads the HUD across a whole recording, splitting the file into chunks
/// that are decoded and read in parallel.
public struct VideoScanner: Sendable {
    public var layout: HUDLayout
    public var samplesPerSecond: Double
    public var chunkSeconds: Double
    public var workers: Int

    public init(
        layout: HUDLayout = .nba2k27,
        samplesPerSecond: Double = 2,
        chunkSeconds: Double = 60,
        workers: Int = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    ) {
        self.layout = layout
        self.samplesPerSecond = samplesPerSecond
        self.chunkSeconds = chunkSeconds
        self.workers = workers
    }

    /// - Parameter progress: called with 0...1 as chunks finish.
    public func scan(
        _ url: URL,
        range: ClosedRange<Double>? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Sample] {
        let info = try await VideoSampler(url: url, samplesPerSecond: samplesPerSecond).info()
        let start = range?.lowerBound ?? 0
        let end = min(range?.upperBound ?? info.duration, info.duration)
        guard end > start else { return [] }

        var chunks: [(index: Int, from: Double, to: Double)] = []
        var cursor = start
        while cursor < end {
            chunks.append((chunks.count, cursor, min(cursor + chunkSeconds, end)))
            cursor += chunkSeconds
        }
        let total = chunks.count
        let layout = layout
        let rate = samplesPerSecond

        return try await withThrowingTaskGroup(of: (Int, [Sample]).self) { group in
            var results = [[Sample]](repeating: [], count: total)
            var next = 0
            var done = 0

            func addNext() {
                guard next < total else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    let reader = HUDReader(layout: layout)
                    var samples: [Sample] = []
                    try await VideoSampler(url: url, samplesPerSecond: rate).run(from: chunk.from) { t, frame in
                        guard t < chunk.to else { return false }
                        try Task.checkCancellation()
                        samples.append(Sample(
                            t: (t * 100).rounded() / 100,
                            stats: reader.readStats(frame),
                            feed: try reader.readFeed(frame)
                        ))
                        return true
                    }
                    return (chunk.index, samples)
                }
            }

            for _ in 0..<min(workers, total) { addNext() }
            while let (index, samples) = try await group.next() {
                results[index] = samples
                done += 1
                progress(Double(done) / Double(total))
                addNext()
            }
            return results.flatMap { $0 }
        }
    }
}
