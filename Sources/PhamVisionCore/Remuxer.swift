import Foundation

/// Re-packages recordings macOS can't open (MKV, FLV, TS) into a temporary
/// MP4 so they can be scanned and previewed.
///
/// Nothing is re-encoded: the video and audio are copied as they are into a
/// different container, so it is fast and loses no quality. The work is done
/// by ffmpeg, borrowed from LosslessCut (which ships its own copy) or from a
/// Homebrew install, so PhamVision doesn't bundle one.
public enum Remuxer {
    /// Containers that hold MP4-compatible video but that macOS can't read.
    public static let extensions: Set<String> = ["mkv", "flv", "ts", "m2ts", "mts"]

    public static func needsRemux(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public enum RemuxError: LocalizedError, Equatable {
        case ffmpegNotFound
        case unsupportedVideo(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "PhamVision reads this kind of file with help from LosslessCut. Install LosslessCut (it's free), then scan the recording again."
            case .unsupportedVideo(let codec):
                return "This recording's video is encoded as \(codec.uppercased()), which macOS can't play. Record with H.264 or HEVC (H.265) instead."
            case .notEnoughSpace(let needed, let available):
                let f = ByteCountFormatter()
                return "PhamVision needs \(f.string(fromByteCount: needed)) of free disk space to read this recording, and only \(f.string(fromByteCount: available)) is free. The space is given back as soon as the scan is closed."
            case .failed(let reason):
                return "The recording couldn't be prepared for scanning. ffmpeg said: \(reason)"
            }
        }
    }

    /// Where ffmpeg might be, most preferred first.
    public static func ffmpegCandidates(losslessCut: URL? = nil) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var apps = [URL(fileURLWithPath: "/Applications/LosslessCut.app"), home.appendingPathComponent("Applications/LosslessCut.app")]
        if let losslessCut { apps.insert(losslessCut, at: 0) }
        return apps.map { $0.appendingPathComponent("Contents/Resources/ffmpeg") } + [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ]
    }

    public static func findFFmpeg(losslessCut: URL? = nil) -> URL? {
        ffmpegCandidates(losslessCut: losslessCut).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Folder for temporary MP4s. Emptied by `removeLeftovers()`.
    public static var workFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("PhamVision/Remux", isDirectory: true)
    }

    /// Deletes temporary MP4s left behind by a crash or force-quit.
    public static func removeLeftovers() {
        try? FileManager.default.removeItem(at: workFolder)
    }

    /// What ffmpeg reports about a file's streams.
    public struct Probe: Sendable, Equatable {
        public var duration: Double?
        public var videoCodec: String?
        public var audioCodec: String?
    }

    /// Parses the stream summary ffmpeg prints for `-i file`.
    public static func parseProbe(_ text: String) -> Probe {
        var probe = Probe()
        if let m = text.firstMatch(of: /Duration: (\d+):(\d\d):(\d\d(?:\.\d+)?)/) {
            probe.duration = (Double(m.1) ?? 0) * 3600 + (Double(m.2) ?? 0) * 60 + (Double(m.3) ?? 0)
        }
        if let m = text.firstMatch(of: /Stream #[^\n]*?Video: (\w+)/) { probe.videoCodec = String(m.1).lowercased() }
        if let m = text.firstMatch(of: /Stream #[^\n]*?Audio: (\w+)/) { probe.audioCodec = String(m.1).lowercased() }
        return probe
    }

    /// The ffmpeg arguments that copy `source` into an MP4 at `destination`.
    public static func arguments(source: URL, destination: URL, probe: Probe) throws -> [String] {
        guard let video = probe.videoCodec else { throw RemuxError.failed("no video stream found") }
        guard ["h264", "hevc", "av1"].contains(video) else { throw RemuxError.unsupportedVideo(video) }
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-map", "0:v:0", "-c:v", "copy"]
        // QuickTime only plays HEVC in MP4 when it carries this tag.
        if video == "hevc" { args += ["-tag:v", "hvc1"] }
        // Keep the sound for previews when MP4 can carry it; otherwise go silent.
        if let audio = probe.audioCodec, ["aac", "mp3", "ac3", "eac3", "alac"].contains(audio) {
            args += ["-map", "0:a:0", "-c:a", "copy"]
        }
        return args + ["-progress", "pipe:1", "-nostats", "-f", "mp4", destination.path]
    }

    /// Copies `source` into a new temporary MP4 and returns its location.
    /// The caller deletes the file when done with it.
    public static func remux(
        _ source: URL,
        ffmpeg: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let probe = parseProbe(try await run(ffmpeg, ["-hide_banner", "-i", source.path]).stderr)

        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        if let free = try? workFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < size + 500_000_000 {
            throw RemuxError.notEnoughSpace(needed: size + 500_000_000, available: free)
        }

        let destination = workFolder.appendingPathComponent(UUID().uuidString + ".mp4")
        let args = try arguments(source: source, destination: destination, probe: probe)
        do {
            let result = try await run(ffmpeg, args) { line in
                // "out_time_us=12345678" lines report how much has been written.
                guard let duration = probe.duration, duration > 0, line.hasPrefix("out_time_us="),
                      let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
                progress(min(1, micros / 1_000_000 / duration))
            }
            try Task.checkCancellation()
            guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
                let reason = result.stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(result.status)"
                throw RemuxError.failed(reason)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Runs a tool to completion, stopping it if the task is cancelled.
    private static func run(
        _ tool: URL,
        _ arguments: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let errors = Collected()
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let onOutputLine, !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { onOutputLine(String(line)) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    errors.append(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: (finished.terminationStatus, errors.text))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: RemuxError.failed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Thread-safe byte buffer for a pipe's output.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(more)
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
