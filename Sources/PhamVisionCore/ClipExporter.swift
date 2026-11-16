@preconcurrency import AVFoundation
import Foundation

/// Saves clips as MP4 files, copying the original video and sound without
/// re-encoding, so it's fast and loses no quality.
///
/// Uses macOS's own video tools. Cuts are exact: each file starts and ends
/// at the clip's times, the way QuickTime and most players show it.
public enum ClipExporter {
    public enum ExportError: LocalizedError, Equatable {
        case noVideo
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideo: return "The recording has no video PhamVision can copy."
            case .failed(let reason): return "The clips couldn't be saved: \(reason)"
            }
        }
    }

    /// Saves each clip as its own file in `folder`, named by `names`.
    /// `progress` gets 0...1 across all clips. Returns the files written.
    public static func exportSeparately(
        _ clips: [Clip], from source: URL, to folder: URL, names: [String],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        precondition(names.count == clips.count)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(names[index]).appendingPathExtension("mp4")
            let done = Double(index), total = Double(clips.count)
            try await export([clip], from: source, to: url) { progress((done + $0) / total) }
            written.append(url)
        }
        progress(1)
        return written
    }

    /// Joins the clips, in order, into one highlight reel.
    public static func exportReel(
        _ clips: [Clip], from source: URL, to file: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try await export(clips, from: source, to: file, progress: progress)
        progress(1)
    }

    /// Builds a composition of the clips' time ranges (main video and first
    /// sound track only) and exports it as passthrough MP4.
    static func export(
        _ clips: [Clip], from source: URL, to file: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let length = try await asset.load(.duration)

        let composition = AVMutableComposition()
        guard let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.failed("couldn't prepare the video") }
        videoOut.preferredTransform = try await video.load(.preferredTransform)
        let audioOut = audio == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for clip in clips {
            let start = CMTime(seconds: max(0, clip.start), preferredTimescale: 600)
            let end = CMTimeMinimum(CMTime(seconds: clip.end, preferredTimescale: 600), length)
            guard end > start else { continue }
            let range = CMTimeRange(start: start, end: end)
            try videoOut.insertTimeRange(range, of: video, at: cursor)
            if let audio, let audioOut { try audioOut.insertTimeRange(range, of: audio, at: cursor) }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw ExportError.failed("the clips are empty") }

        try? FileManager.default.removeItem(at: file)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.failed("macOS couldn't start the export")
        }
        session.outputURL = file
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler {
            await box.session.export()
        } onCancel: {
            box.session.cancelExport()
        }
        switch session.status {
        case .completed:
            return
        case .cancelled:
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: file)
            throw ExportError.failed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    /// Lets the export session be cancelled and polled from other tasks.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// A file name for a clip: "03 G1 3rd 4.43 +3 PTS ★★★".
    public static func fileName(for clip: Clip, number: Int, of total: Int, stars: Int? = nil) -> String {
        let width = String(total).count
        var parts = [String(format: "%0\(width)d", number), "G\(clip.plays.first?.game ?? 1)"]
        if let clock = clip.plays.first?.clock { parts.append(clock) }
        parts.append(clip.plays.map(\.shortName).joined(separator: " + "))
        if let stars { parts.append(String(repeating: "★", count: stars)) }
        return sanitize(parts.joined(separator: " "))
    }

    /// Replaces characters that Finder or other systems reject in file names.
    public static func sanitize(_ name: String) -> String {
        var out = name.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        out = out.replacingOccurrences(of: "\\", with: "-")
        return String(out.prefix(180)).trimmingCharacters(in: .whitespaces)
    }
}

extension Play {
    /// "+3 PTS", "+1 AST", "Steal".
    public var shortName: String {
        if kind == .feed { return detail }
        return detail.components(separatedBy: " (").first ?? detail
    }
}
