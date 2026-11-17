@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Foundation

/// Makes vertical 1080×1920 videos for TikTok, Reels and Shorts: the whole
/// gameplay frame in the middle, a blurred zoomed copy filling the space
/// behind it, and a caption above. Unlike the other exports this one has to
/// re-encode the video, so it takes a few seconds per clip.
public enum VerticalExporter {
    public static let size = CGSize(width: 1080, height: 1920)

    /// Saves each clip as its own vertical MP4 in `folder`.
    public static func export(
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
            try await exportOne(clip, from: source, to: url) { progress((done + $0) / total) }
            written.append(url)
        }
        progress(1)
        return written
    }

    /// "+3 PTS + Steal" for the big line, "G1 · 4th 0:57" for the small one.
    public static func caption(for clip: Clip) -> (title: String, detail: String) {
        let title = clip.plays.map(\.shortName).joined(separator: " + ")
        var detail = "G\(clip.plays.first?.game ?? 1)"
        if let clock = clip.plays.first?.clock { detail += " · " + clock }
        return (title, detail)
    }

    static func exportOne(
        _ clip: Clip, from source: URL, to file: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ClipExporter.ExportError.noVideo }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let length = try await asset.load(.duration)
        let frameRate = try await video.load(.nominalFrameRate)

        let composition = AVMutableComposition()
        guard let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ClipExporter.ExportError.failed("couldn't prepare the video") }
        let start = CMTime(seconds: max(0, clip.start), preferredTimescale: 600)
        let end = CMTimeMinimum(CMTime(seconds: clip.end, preferredTimescale: 600), length)
        guard end > start else { throw ClipExporter.ExportError.failed("the clip is empty") }
        let range = CMTimeRange(start: start, end: end)
        try videoOut.insertTimeRange(range, of: video, at: .zero)
        if let audio, let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioOut.insertTimeRange(range, of: audio, at: .zero)
        }

        let text = captionImage(caption(for: clip))
        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            request.finish(with: frame(request.sourceImage, caption: text), context: nil)
        }
        videoComposition.renderSize = size
        let fps = frameRate > 0 ? frameRate : 60
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(fps.rounded(), 60)))

        try? FileManager.default.removeItem(at: file)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipExporter.ExportError.failed("macOS couldn't start the export")
        }
        session.videoComposition = videoComposition
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
        case .completed: return
        case .cancelled:
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: file)
            throw ClipExporter.ExportError.failed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    /// One output frame: blurred background, gameplay in the middle, caption above.
    static func frame(_ source: CIImage, caption: CIImage?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let src = source.extent
        guard src.width > 0, src.height > 0 else { return source }

        // Background: fill the canvas height, centre, blur, darken.
        let fill = size.height / src.height
        let background = source
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .transformed(by: CGAffineTransform(translationX: (size.width - src.width * fill) / 2 - src.minX * fill,
                                               y: -src.minY * fill))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.2])
            .cropped(to: canvas)

        // Foreground: the whole frame at full width, centred vertically.
        let fit = size.width / src.width
        let height = src.height * fit
        let foreground = source
            .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: -src.minX * fit, y: (size.height - height) / 2 - src.minY * fit))

        var out = foreground.composited(over: background)
        if let caption {
            let x = (size.width - caption.extent.width) / 2
            let y = (size.height + height) / 2 + 80
            out = caption.transformed(by: CGAffineTransform(translationX: x - caption.extent.minX, y: y - caption.extent.minY))
                .composited(over: out)
        }
        return out.cropped(to: canvas)
    }

    /// The caption as an image: a big bold line with a smaller one under it.
    static func captionImage(_ caption: (title: String, detail: String)) -> CIImage? {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 12
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSMutableAttributedString(string: caption.title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: titleSize(for: caption.title), weight: .heavy),
            .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: caption.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
            .foregroundColor: NSColor(red: 0.18, green: 0.90, blue: 0.71, alpha: 1), .shadow: shadow, .paragraphStyle: paragraph,
        ]))
        let filter = CIFilter(name: "CIAttributedTextImageGenerator")
        filter?.setValue(text, forKey: "inputText")
        filter?.setValue(1.0, forKey: "inputScaleFactor")
        return filter?.outputImage
    }

    /// Long combined captions get a smaller font so they fit the width.
    static func titleSize(for title: String) -> CGFloat {
        switch title.count {
        case ..<14: return 96
        case ..<24: return 72
        default: return 52
        }
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}
