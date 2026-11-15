@preconcurrency import AVFoundation
import CoreVideo

/// Decodes a video front to back and hands every Nth frame to a callback.
///
/// Sequential decoding is used instead of seeking because recordings have
/// sparse keyframes (every ~2 s), so each seek would decode up to 2 s of
/// frames anyway.
public struct VideoSampler: Sendable {
    public let url: URL
    /// Samples per second of video to hand to the callback.
    public let samplesPerSecond: Double

    public init(url: URL, samplesPerSecond: Double = 2) {
        self.url = url
        self.samplesPerSecond = samplesPerSecond
    }

    public struct Info: Sendable {
        public let duration: Double
        public let width: Int
        public let height: Int
        public let frameRate: Double
    }

    public enum SamplerError: LocalizedError, Equatable {
        case noVideoTrack
        case unsupportedFormat(String)
        case cannotRead(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "This file has no video track PhamVision can read."
            case .unsupportedFormat(let ext) where ext == "mkv":
                return """
                macOS can't read MKV files. Scan the MP4 version of this recording instead. \
                To make one without losing quality, open the MKV in LosslessCut, set the output format to MP4 \
                and export the whole file; it only re-packages the video, so it takes seconds.
                """
            case .unsupportedFormat(let ext):
                return "macOS can't read .\(ext) files. Convert the recording to MP4 or MOV and scan that."
            case .cannotRead(let reason):
                return "Couldn't read the video: \(reason)"
            }
        }
    }

    /// Opens the asset's video track, turning "format not supported" into a
    /// message that says what to do.
    private func videoTrack(_ asset: AVURLAsset) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch let error as NSError where error.domain == AVFoundationErrorDomain
            && error.code == AVError.Code.fileFormatNotRecognized.rawValue {
            throw SamplerError.unsupportedFormat(url.pathExtension.lowercased())
        } catch let error as NSError where error.domain == AVFoundationErrorDomain {
            let ext = url.pathExtension.lowercased()
            if ["mkv", "webm", "flv", "avi"].contains(ext) { throw SamplerError.unsupportedFormat(ext) }
            throw SamplerError.cannotRead(error.localizedFailureReason ?? error.localizedDescription)
        }
        guard let track = tracks.first else { throw SamplerError.noVideoTrack }
        return track
    }

    public func info() async throws -> Info {
        let asset = AVURLAsset(url: url)
        let track = try await videoTrack(asset)
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = size.applying(transform)
        let duration = try await asset.load(.duration).seconds
        return Info(
            duration: duration,
            width: Int(abs(oriented.width)),
            height: Int(abs(oriented.height)),
            frameRate: Double(fps)
        )
    }

    /// Runs the decode loop. `handler` receives the presentation time in
    /// seconds and a bi-planar 4:2:0 pixel buffer. Return `false` to stop.
    ///
    /// Runs on the caller's actor, so the handler can touch the caller's state.
    public func run(
        from startSeconds: Double = 0,
        isolation: isolated (any Actor)? = #isolation,
        handler: (Double, CVPixelBuffer) throws -> Bool
    ) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await videoTrack(asset)
        let reader = try AVAssetReader(asset: asset)
        if startSeconds > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                duration: .positiveInfinity
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw SamplerError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let interval = 1.0 / samplesPerSecond
        var nextSample = startSeconds
        while let buffer = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard t + 0.0001 >= nextSample, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            // Keep a fixed grid even if frames are dropped or timestamps jitter.
            while nextSample <= t { nextSample += interval }
            if try !handler(t, pixels) { return }
        }
        if reader.status == .failed {
            throw SamplerError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
    }
}
