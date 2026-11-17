import AppKit
import Observation
import PhamVisionCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case failed(Failure)
    }

    /// Something that went wrong, worded for the person using the app.
    struct Failure: Equatable {
        var title: String
        var message: String
        /// Scanning the same file again could work.
        var canRetry = false
        /// A video format macOS can't read (MKV and friends), which LosslessCut can turn into MP4.
        var needsConverting = false
    }

    /// How far a running scan has got.
    struct ScanProgress: Equatable {
        enum Stage: Equatable {
            case opening
            /// Re-packaging an MKV (or similar) into an MP4 macOS can read.
            case converting
            case reading
            case clocks(done: Int, total: Int)
        }

        /// The stat-line pass is nearly all of the work; reading the game clocks is the rest.
        static let readingShare = 0.94

        let started: Date
        var stage: Stage = .opening
        /// When the current stage began, and how much of it was done at `updated`.
        var stageStarted: Date
        var stageFraction: Double = 0
        var updated: Date
        /// Share of the bar given to converting; zero for files that don't need it.
        var convertShare = 0.0

        init(started: Date) {
            self.started = started
            stageStarted = started
            updated = started
        }

        /// 0...1 for the progress bar.
        var overall: Double {
            switch stage {
            case .opening: return 0
            case .converting: return stageFraction * convertShare
            case .reading: return convertShare + stageFraction * (Self.readingShare - convertShare)
            case .clocks: return Self.readingShare + (1 - Self.readingShare) * stageFraction
            }
        }

        mutating func begin(_ stage: Stage, at now: Date = Date()) {
            self.stage = stage
            stageStarted = now
            updated = now
            stageFraction = 0
            if case .clocks(let done, let total) = stage, total > 0 { stageFraction = Double(done) / Double(total) }
        }

        mutating func advance(_ fraction: Double, at now: Date = Date()) {
            // Progress callbacks can arrive out of order; never go backwards.
            guard fraction > stageFraction else { return }
            stageFraction = min(1, fraction)
            updated = now
        }

        mutating func clocksRead(_ done: Int, of total: Int) {
            stage = .clocks(done: done, total: total)
            advance(total > 0 ? Double(done) / Double(total) : 1)
        }

        /// Seconds left in the current stage, extrapolated from how fast it has gone so far.
        /// Counts down between updates so the estimate keeps moving.
        func secondsLeft(at now: Date) -> Double? {
            guard stage != .opening, stageFraction >= 0.03, stageFraction < 1 else { return nil }
            let spent = updated.timeIntervalSince(stageStarted)
            guard spent > 1 else { return nil }
            let left = spent / stageFraction * (1 - stageFraction) - now.timeIntervalSince(updated)
            return max(0, left)
        }
    }

    /// A request that would throw away a running scan or unsaved clips, waiting for a yes.
    struct PendingDiscard: Equatable {
        /// The recording to scan next, or nil to go back to the drop screen.
        let next: URL?
        let whileScanning: Bool
    }

    /// Wording for an "are you sure?" question.
    struct Confirmation {
        var title: String
        var message: String
        var confirm: String
        var cancel: String
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: ScanProgress?
    private(set) var video: URL?
    /// The file macOS can actually play: the recording itself, or a temporary
    /// MP4 copy when the recording is an MKV. Used for scanning and previews;
    /// LosslessCut always gets the original.
    private(set) var playable: URL?
    private var temporaryFile: URL?
    private(set) var duration: Double = 0
    private(set) var plays: [Play] = []
    private(set) var scanSeconds: Double = 0
    var settings: ClipSettings = AppModel.savedSettings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            rebuild()
        }
    }
    private(set) var clips: [Clip] = []
    /// Each game's plays checked against its final stat line.
    private(set) var gameChecks: [GameSummary] = []
    /// 1 to 3 stars per clip, relative to the other clips in this recording.
    private(set) var stars: [Clip.ID: Int] = [:]
    /// Plays the user unticked. Stored by play rather than clip, because clips
    /// are rebuilt and renumbered whenever the filters or clip length change.
    private(set) var excludedPlays: Set<Int> = []
    /// Show the highest-rated clips first instead of in recording order.
    var bestFirst = UserDefaults.standard.bool(forKey: "sortBestFirst") {
        didSet { UserDefaults.standard.set(bestFirst, forKey: "sortBestFirst") }
    }
    /// 0...1 while clips are being saved.
    private(set) var exportProgress: Double?
    private(set) var exportTitle = ""
    private var exportTask: Task<Void, Never>?
    var notice: String?
    /// Set when exporting would replace a LosslessCut project that already exists.
    var pendingOverwrite: URL?
    var pendingDiscard: PendingDiscard?
    /// LosslessCut's location, refreshed whenever PhamVision comes to the front
    /// so installing it mid-session is picked up.
    private(set) var losslessCutURL: URL?
    /// The clips and ticks as they were when last sent to LosslessCut, saved
    /// as CSV or exported.
    private var savedClips: [Clip]?
    private var savedExcluded: Set<Int>?

    private var task: Task<Void, Never>?
    /// Bumped for every scan so a cancelled one can never overwrite a newer one's state.
    private var scanID = 0
    private var activity: (any NSObjectProtocol)?

    static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        + ["mkv", "mov", "mp4", "m4v", "ts"].compactMap { UTType(filenameExtension: $0) }

    /// Video formats macOS can't decode. They go straight to the scanner,
    /// which explains how to convert them.
    private static let unreadableVideoExtensions: Set<String> = ["mkv", "webm", "flv", "avi", "wmv", "m2ts", "mts", "ts"]

    init() {
        losslessCutURL = Self.findLosslessCut()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLosslessCut() }
        }
    }

    // MARK: Choosing a recording

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the recording of your stream (MP4, MOV or MKV)"
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Scans `url`, first asking if that would throw away a running scan or unsaved clips.
    func open(_ url: URL) {
        if needsDiscardConfirmation {
            pendingDiscard = PendingDiscard(next: url, whileScanning: phase == .scanning)
        } else {
            scan(url)
        }
    }

    /// "Scan Another": back to the drop screen, asking first if clips would be lost.
    func startOver() {
        if needsDiscardConfirmation {
            pendingDiscard = PendingDiscard(next: nil, whileScanning: phase == .scanning)
        } else {
            reset()
        }
    }

    func confirmDiscard() {
        guard let pending = pendingDiscard else { return }
        pendingDiscard = nil
        if let next = pending.next { scan(next) } else { reset() }
    }

    var discardConfirmation: Confirmation? {
        guard let pending = pendingDiscard else { return nil }
        let current = quoted(video)
        if pending.whileScanning {
            let then = pending.next.map { " and scan \(quoted($0)) instead" } ?? ""
            return Confirmation(
                title: "Stop scanning \(current)?",
                message: "The progress so far will be lost\(then).",
                confirm: "Stop Scan",
                cancel: "Keep Scanning"
            )
        }
        return Confirmation(
            title: "Discard these clips?",
            message: unsavedExplanation,
            confirm: "Discard Clips",
            cancel: "Cancel"
        )
    }

    private var unsavedExplanation: String {
        let what = savedClips == nil
            ? "You haven't exported the clips from \(quoted(video)), opened them in LosslessCut or saved them as a CSV."
            : "You've changed the clips from \(quoted(video)) since you last exported or saved them."
        return what + " Getting them back means scanning the recording again, which took \(Format.rough(scanSeconds))."
    }

    /// What to ask before quitting, if quitting would lose work.
    var quitConfirmation: Confirmation? {
        if exportProgress != nil {
            return Confirmation(
                title: "Stop saving clips and quit?",
                message: "The clips saved so far stay where they are. The rest won't be saved.",
                confirm: "Quit",
                cancel: "Keep Saving"
            )
        }
        switch phase {
        case .scanning:
            return Confirmation(
                title: "Stop scanning and quit?",
                message: "PhamVision is still scanning \(quoted(video)). If you quit now, the scan starts again from the beginning next time.",
                confirm: "Quit",
                cancel: "Keep Scanning"
            )
        case .done where hasUnsavedResults:
            return Confirmation(
                title: "Quit without saving your clips?",
                message: unsavedExplanation,
                confirm: "Quit",
                cancel: "Cancel"
            )
        default:
            return nil
        }
    }

    /// A scan or export is still running.
    var hasBackgroundWork: Bool { phase == .scanning || exportProgress != nil }

    /// Stops any scan or export and waits (up to 3 seconds) for its
    /// background work to wind down, so quitting never pulls the app out
    /// from under video decoding or text recognition still in progress.
    func stopAllWork() async {
        let running = [task, exportTask].compactMap { $0 }
        task?.cancel()
        exportTask?.cancel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in running { await task.value } }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        stopScan()
    }

    var hasUnsavedResults: Bool {
        phase == .done && !plays.isEmpty && (savedClips != clips || savedExcluded != excludedPlays)
    }

    private func markSaved() {
        savedClips = clips
        savedExcluded = excludedPlays
    }

    private var needsDiscardConfirmation: Bool {
        switch phase {
        case .scanning: return true
        case .done: return hasUnsavedResults
        case .idle, .failed: return false
        }
    }

    // MARK: Scanning

    func scan(_ url: URL) {
        stopScan()
        scanID += 1
        let id = scanID
        video = url
        duration = 0
        plays = []
        clips = []
        savedClips = nil
        notice = nil
        pendingOverwrite = nil
        pendingDiscard = nil
        if let problem = Self.preflight(url) {
            phase = .failed(problem)
            return
        }
        let started = Date()
        progress = ScanProgress(started: started)
        phase = .scanning
        beginLongWork()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        task = Task { await runScan(url, id: id, started: started) }
    }

    func retry() {
        if let video { scan(video) }
    }

    func cancelScan() { reset() }

    func reset() {
        stopScan()
        scanID += 1
        video = nil
        duration = 0
        plays = []
        clips = []
        savedClips = nil
        notice = nil
        pendingOverwrite = nil
        pendingDiscard = nil
        phase = .idle
    }

    private func stopScan() {
        task?.cancel()
        task = nil
        exportTask?.cancel()
        exportTask = nil
        exportProgress = nil
        gameChecks = []
        stars = [:]
        excludedPlays = []
        savedExcluded = nil
        progress = nil
        endLongWork()
        playable = nil
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        temporaryFile = nil
    }

    /// For an MKV or similar, makes a temporary MP4 copy (no re-encoding) and
    /// returns it; other recordings are returned as they are.
    private func playableCopy(of url: URL, id: Int) async throws -> URL {
        guard Remuxer.needsRemux(url) else { return url }
        guard let ffmpeg = Remuxer.findFFmpeg(losslessCut: losslessCutURL) else {
            throw Remuxer.RemuxError.ffmpegNotFound
        }
        progress?.convertShare = 0.08
        progress?.begin(.converting)
        let copy = try await Remuxer.remux(url, ffmpeg: ffmpeg) { fraction in
            Task { @MainActor in
                guard id == self.scanID, self.progress?.stage == .converting else { return }
                self.progress?.advance(fraction)
                DockProgress.show(self.progress?.overall ?? 0)
            }
        }
        guard id == scanID, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: copy)
            throw CancellationError()
        }
        temporaryFile = copy
        return copy
    }

    private func runScan(_ original: URL, id: Int, started: Date) async {
        var opened = false
        do {
            let url = try await playableCopy(of: original, id: id)
            let info = try await VideoSampler(url: url).info()
            guard id == scanID else { return }
            opened = true
            playable = url
            duration = info.duration
            progress?.begin(.reading)

            let samples = try await VideoScanner().scan(url) { fraction in
                Task { @MainActor in
                    // Drop updates that arrive after the scan moved on, was cancelled or replaced.
                    guard id == self.scanID, self.progress?.stage == .reading else { return }
                    self.progress?.advance(fraction)
                    DockProgress.show(self.progress?.overall ?? 0)
                }
            }
            try Task.checkCancellation()
            var detection = await Task.detached(priority: .userInitiated) { PlayDetector().analyze(samples) }.value
            try Task.checkCancellation()

            guard id == scanID else { return }
            progress?.begin(.clocks(done: 0, total: detection.plays.count))
            GameClock.apply(try await readClocks(url, at: detection.plays.map(\.time), id: id), to: &detection.plays)
            PlayDetector.splitGamesByClock(&detection.plays, games: &detection.games)
            try Task.checkCancellation()

            guard id == scanID else { return }
            let found = detection.plays
            plays = found
            gameChecks = detection.games
            excludedPlays = []
            scanSeconds = Date().timeIntervalSince(started)
            rebuild()
            progress = nil
            phase = .done
            endLongWork()
            let name = original.lastPathComponent
            Attention.finished(
                title: found.isEmpty ? "No plays found" : "Scan finished",
                body: found.isEmpty
                    ? "PhamVision couldn't find the stat line in “\(name)”."
                    : "Found \(Self.count(found.count, "play")) in “\(name)”, ready to review.",
                after: scanSeconds
            )
        } catch {
            guard id == scanID, !Task.isCancelled, !(error is CancellationError) else { return }
            let failure = Self.describe(error, reading: original, opened: opened)
            progress = nil
            phase = .failed(failure)
            endLongWork()
            Attention.finished(title: "Scan stopped", body: failure.title, after: Date().timeIntervalSince(started))
        }
    }

    /// Reads the scoreboard (clock and score) for each play in about 20 batches,
    /// so the progress bar keeps moving and Cancel takes effect quickly. Each
    /// play's scoreboard is read on its own either way, so batching doesn't
    /// change the results.
    private func readClocks(_ url: URL, at times: [Double], id: Int) async throws -> [Int: Scoreboard] {
        var labels: [Int: Scoreboard] = [:]
        let batch = max(8, (times.count + 19) / 20)
        var start = 0
        while start < times.count {
            try Task.checkCancellation()
            let end = min(start + batch, times.count)
            for (offset, label) in await GameClock.read(url, at: Array(times[start..<end])) {
                labels[start + offset] = label
            }
            start = end
            guard id == scanID else { break }
            progress?.clocksRead(end, of: times.count)
            DockProgress.show(progress?.overall ?? 1)
        }
        return labels
    }

    /// Keeps the Mac awake and shows progress on the Dock icon while a scan runs.
    private func beginLongWork() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Scanning a recording"
            )
        }
        Attention.askPermission()
        DockProgress.show(0)
    }

    private func endLongWork() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        DockProgress.hide()
    }

    /// Catches files that can't be scanned before any work starts.
    private static func preflight(_ url: URL) -> Failure? {
        let name = url.lastPathComponent
        var isFolder: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            return Failure(
                title: "Couldn't find that file",
                message: "“\(name)” may have been moved, renamed or deleted, or the drive it's on was disconnected."
            )
        }
        if isFolder.boolValue {
            return Failure(
                title: "That's a folder",
                message: "Drop the recording itself, the MP4 or MOV file, rather than the folder it's in."
            )
        }
        let ext = url.pathExtension.lowercased()
        if unreadableVideoExtensions.contains(ext) { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: ext)
        if let type, type.conforms(to: .movie) { return nil }
        if let type, type.conforms(to: .audio) {
            return Failure(
                title: "That's an audio file",
                message: "“\(name)” has sound but no picture, so there's no stat line to read. Choose the video recording of your stream instead."
            )
        }
        return Failure(
            title: "That file isn't a video",
            message: "PhamVision needs the recording of your stream, saved as an MP4 or MOV file."
        )
    }

    /// Turns an error from the scanner into something a person can act on.
    /// `opened` says whether the file opened as a video before things went wrong.
    private static func describe(_ error: Error, reading url: URL, opened: Bool) -> Failure {
        let name = url.lastPathComponent
        if !FileManager.default.fileExists(atPath: url.path) {
            return Failure(
                title: "The recording went missing",
                message: "“\(name)” was moved, renamed or deleted, or the drive it's on was disconnected, before the scan finished."
            )
        }
        let unfinished = "This usually means the recording didn't finish saving, for example because the recorder "
            + "or the Mac stopped unexpectedly. Check whether it plays in QuickTime Player."
        if let error = error as? Remuxer.RemuxError {
            let kind = url.pathExtension.uppercased()
            switch error {
            case .ffmpegNotFound:
                return Failure(
                    title: "\(kind) files need LosslessCut installed",
                    message: error.errorDescription ?? "",
                    canRetry: true,
                    needsConverting: true
                )
            case .notEnoughSpace:
                return Failure(title: "Not enough free disk space", message: error.errorDescription ?? "", canRetry: true)
            case .unsupportedVideo:
                return Failure(title: "This recording's video format isn't supported", message: error.errorDescription ?? "")
            case .failed:
                return Failure(
                    title: "This \(kind) file couldn't be read",
                    message: (error.errorDescription ?? "") + "\n\n" + unfinished,
                    canRetry: true
                )
            }
        }
        if let error = error as? VideoSampler.SamplerError {
            switch error {
            case .unsupportedFormat(let ext) where ["mp4", "mov", "m4v"].contains(ext):
                return Failure(
                    title: "This recording can't be opened",
                    message: "macOS doesn't recognise “\(name)” as a video it can play. " + unfinished
                )
            case .cannotRead(let reason) where !opened:
                return Failure(
                    title: "This recording can't be opened",
                    message: "macOS couldn't open “\(name)” as a video. It says: \(reason)\n\n" + unfinished
                )
            case .unsupportedFormat(let ext):
                return Failure(
                    title: ext.isEmpty ? "This file needs converting first" : "\(ext.uppercased()) files need converting first",
                    message: error.errorDescription ?? "",
                    needsConverting: true
                )
            case .noVideoTrack:
                return Failure(
                    title: "There's no video in this file",
                    message: "“\(name)” doesn't contain any video, so there's no stat line to read. Choose the full recording of your stream."
                )
            case .cannotRead:
                return Failure(
                    title: "The scan stopped partway",
                    message: (error.errorDescription ?? "") + "\n\nIf the recording is on an external drive, check it's still connected, then try again.",
                    canRetry: true
                )
            }
        }
        return Failure(
            title: "That recording couldn't be scanned",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            canRetry: true
        )
    }

    // MARK: Results

    func count(_ kind: PlayKind) -> Int { plays.count { $0.kind == kind } }

    var games: Int { plays.map(\.game).max() ?? 0 }
    var totalClipSeconds: Double { clips.reduce(0) { $0 + $1.duration } }

    func clip(_ id: Clip.ID) -> Clip? { clips.first { $0.id == id } }

    private func rebuild() {
        clips = ClipBuilder.build(plays, settings: settings, videoDuration: duration)
        stars = ClipRating.stars(clips)
    }

    /// The clips in the order the list shows them.
    var shownClips: [Clip] {
        guard bestFirst else { return clips }
        return clips.sorted {
            let a = ClipRating.excitement($0), b = ClipRating.excitement($1)
            return a != b ? a > b : $0.start < $1.start
        }
    }

    // MARK: Ticking clips

    /// A clip is kept unless every play in it was unticked.
    func isKept(_ clip: Clip) -> Bool { !clip.plays.allSatisfy { excludedPlays.contains($0.id) } }

    func setKept(_ clip: Clip, _ keep: Bool) {
        for play in clip.plays {
            if keep { excludedPlays.remove(play.id) } else { excludedPlays.insert(play.id) }
        }
    }

    /// Ticks every clip with at least `minStars` stars and unticks the rest.
    func keepOnly(minStars: Int) {
        excludedPlays = []
        for clip in clips where (stars[clip.id] ?? 1) < minStars { setKept(clip, false) }
    }

    func untickAll() {
        excludedPlays = Set(plays.map(\.id))
    }

    /// The ticked clips, in list order.
    var keptClips: [Clip] { shownClips.filter(isKept) }
    var keptSeconds: Double { keptClips.reduce(0) { $0 + $1.duration } }

    // MARK: Accuracy check

    /// Games whose plays don't add up to their stat line.
    var gamesWithGaps: [GameSummary] { gameChecks.filter { !$0.checksOut } }

    /// A clip covering a gap in a game's plays, so it can be watched.
    func clip(for gap: GameSummary.Gap, in game: GameSummary) -> Clip {
        let start = max(0, gap.after - 5)
        let end = min(duration > 0 ? duration : gap.before + 5, min(gap.before + 5, start + 120))
        let play = Play(
            id: -1, time: gap.after, kind: gap.kind,
            detail: "\(gap.unit) \(gap.from) → \(gap.to), not matched to a play", game: game.games.first ?? game.index
        )
        return Clip(id: -1, start: start, end: max(end, start + 1), plays: [play])
    }

    // MARK: Exporting clips

    /// Saves each ticked clip as its own MP4 in a new folder next to where
    /// the user chooses.
    func exportClips() {
        let chosen = keptClips
        guard let video, let source = playable ?? self.video, !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = video.deletingLastPathComponent()
        panel.prompt = "Save Clips Here"
        panel.message = "PhamVision will make a new folder here for the \(Self.count(chosen.count, "clip"))."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let folder = Self.unused(parent.appendingPathComponent(video.deletingPathExtension().lastPathComponent + " clips"))
        let ordered = chosen.sorted { $0.start < $1.start }
        let names = ordered.enumerated().map {
            ClipExporter.fileName(for: $1, number: $0 + 1, of: ordered.count, stars: stars[$1.id])
        }
        runExport(title: "Saving \(Self.count(ordered.count, "clip"))…", result: folder) { progress in
            _ = try await ClipExporter.exportSeparately(ordered, from: source, to: folder, names: names, progress: progress)
        } done: {
            "Saved \(Self.count(ordered.count, "clip")) to “\(folder.lastPathComponent)”."
        }
    }

    /// Joins the ticked clips into one video, in the order the list shows them.
    func exportReel() {
        let chosen = keptClips
        guard let video, let source = playable ?? self.video, !chosen.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = video.deletingLastPathComponent()
        panel.nameFieldStringValue = video.deletingPathExtension().lastPathComponent + " highlights.mp4"
        panel.message = "One video of the \(Self.count(chosen.count, "ticked clip")), \(bestFirst ? "best first" : "in recording order")."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        runExport(title: "Making a highlight reel of \(Self.count(chosen.count, "clip"))…", result: file) { progress in
            try await ClipExporter.exportReel(chosen, from: source, to: file, progress: progress)
        } done: {
            "Saved “\(file.lastPathComponent)” (\(Format.clock(chosen.reduce(0) { $0 + $1.duration })))."
        }
    }

    /// Saves each ticked clip as a vertical 1080×1920 video for TikTok,
    /// Reels and Shorts, in a new folder.
    func exportVertical() {
        let chosen = keptClips
        guard let video, let source = playable ?? self.video, !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = video.deletingLastPathComponent()
        panel.prompt = "Save Videos Here"
        panel.message = "PhamVision will make a new folder here with \(Self.count(chosen.count, "vertical video")), ready to post. This takes a few seconds per clip."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let folder = Self.unused(parent.appendingPathComponent(video.deletingPathExtension().lastPathComponent + " TikToks"))
        let ordered = bestFirst ? chosen : chosen.sorted { $0.start < $1.start }
        let names = ordered.enumerated().map {
            ClipExporter.fileName(for: $1, number: $0 + 1, of: ordered.count, stars: stars[$1.id])
        }
        runExport(title: "Making \(Self.count(ordered.count, "vertical video"))…", result: folder) { progress in
            _ = try await VerticalExporter.export(ordered, from: source, to: folder, names: names, progress: progress)
        } done: {
            "Saved \(Self.count(ordered.count, "vertical video")) to “\(folder.lastPathComponent)”."
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func runExport(
        title: String, result: URL,
        work: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void,
        done: @escaping @MainActor () -> String
    ) {
        exportTask?.cancel()
        exportTitle = title
        exportProgress = 0
        beginExportActivity()
        exportTask = Task {
            defer { self.endExportActivity() }
            do {
                try await work { fraction in
                    Task { @MainActor in
                        if let current = self.exportProgress, fraction > current { self.exportProgress = fraction }
                    }
                }
                guard exportProgress != nil else { return }
                exportProgress = nil
                markSaved()
                notice = done()
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch {
                guard exportProgress != nil else { return }
                exportProgress = nil
                notice = error is CancellationError
                    ? "Stopped saving clips. Any finished ones are in “\(result.lastPathComponent)”."
                    : "Couldn't save the clips: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private var exportActivity: (any NSObjectProtocol)?

    private func beginExportActivity() {
        exportActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Saving clips")
    }

    private func endExportActivity() {
        if let exportActivity { ProcessInfo.processInfo.endActivity(exportActivity) }
        exportActivity = nil
    }

    /// `url`, or "url 2", "url 3"… if something already has that name.
    private static func unused(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) \(n)")
            n += 1
        }
        return candidate
    }

    // MARK: Clip settings, remembered between launches

    nonisolated static let beforeRange: ClosedRange<Double> = 3...60
    nonisolated static let afterRange: ClosedRange<Double> = 0...30

    var usesDefaultClipLength: Bool {
        let defaults = ClipSettings()
        return settings.before == defaults.before && settings.after == defaults.after
    }

    func resetClipLength() {
        let defaults = ClipSettings()
        settings.before = defaults.before
        settings.after = defaults.after
    }

    private enum DefaultsKey {
        static let before = "clipSecondsBefore"
        static let after = "clipSecondsAfter"
        /// Hidden rather than shown kinds, so any new kind of play starts out visible.
        static let hiddenKinds = "hiddenPlayKinds"
        /// Opt-in kinds (everyone else's baskets) the user turned on.
        static let shownOptIn = "shownOptInPlayKinds"
    }

    nonisolated private static func savedSettings() -> ClipSettings {
        var settings = ClipSettings()
        let defaults = UserDefaults.standard
        if let before = defaults.object(forKey: DefaultsKey.before) as? Double {
            settings.before = min(max(before, beforeRange.lowerBound), beforeRange.upperBound)
        }
        if let after = defaults.object(forKey: DefaultsKey.after) as? Double {
            settings.after = min(max(after, afterRange.lowerBound), afterRange.upperBound)
        }
        if let hidden = defaults.stringArray(forKey: DefaultsKey.hiddenKinds) {
            settings.kinds.subtract(hidden.compactMap(PlayKind.init(rawValue:)).filter { !PlayKind.optIn.contains($0) })
        }
        if let shown = defaults.stringArray(forKey: DefaultsKey.shownOptIn) {
            settings.kinds.formUnion(shown.compactMap(PlayKind.init(rawValue:)).filter { PlayKind.optIn.contains($0) })
        }
        return settings
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(settings.before, forKey: DefaultsKey.before)
        defaults.set(settings.after, forKey: DefaultsKey.after)
        let hidden = PlayKind.allCases.filter { !settings.kinds.contains($0) }.map(\.rawValue)
        defaults.set(hidden, forKey: DefaultsKey.hiddenKinds)
        let shownOptIn = PlayKind.optIn.filter { settings.kinds.contains($0) }.map(\.rawValue)
        defaults.set(shownOptIn, forKey: DefaultsKey.shownOptIn)
    }

    // MARK: LosslessCut

    private static func findLosslessCut() -> URL? {
        for id in ["no.mifi.losslesscut", "no.mifi.losslesscut-mac"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let fallback = URL(fileURLWithPath: "/Applications/LosslessCut.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func refreshLosslessCut() {
        let found = Self.findLosslessCut()
        guard found != losslessCutURL else { return }
        losslessCutURL = found
        if found != nil, notice == Self.getLosslessCutNotice { notice = nil }
    }

    func reviewInLosslessCut(overwrite: Bool = false) {
        guard let video, !clips.isEmpty else { return }
        let project = LosslessCut.projectURL(for: video)
        if !overwrite, FileManager.default.fileExists(atPath: project.path) {
            pendingOverwrite = project
            return
        }
        do {
            try LosslessCut.project(
                for: shownClips.sorted { $0.start < $1.start }, mediaFileName: video.lastPathComponent,
                stars: stars, selected: isKept
            ).write(to: project, options: .atomic)
        } catch {
            notice = "Couldn't save the clip list next to the recording: \(error.localizedDescription)"
            return
        }
        markSaved()
        guard let app = losslessCutURL else {
            notice = "Clip list saved next to the recording. Install LosslessCut, then open the recording in it."
            return
        }
        open(video, in: app)
        let ticked = keptClips.count
        notice = ticked == clips.count
            ? "Opened in LosslessCut with \(Self.count(clips.count, "clip")) marked."
            : "Opened in LosslessCut with \(Self.count(clips.count, "clip")) marked, \(ticked) ticked."
    }

    /// For formats macOS can't read: LosslessCut can re-save them as MP4.
    func openVideoInLosslessCut() {
        guard let video, let app = losslessCutURL else { return }
        open(video, in: app)
    }

    /// Opens the recording in LosslessCut.
    ///
    /// macOS calls the completion handler on a background queue. It must be
    /// `@Sendable`: without that, Swift 6.0 and 6.1 treat a closure written
    /// here as main-thread-only and crash the app when it's called from
    /// elsewhere (this crashed 0.2.0 right after LosslessCut opened).
    private func open(_ video: URL, in app: URL) {
        NSWorkspace.shared.open([video], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in self.notice = "Couldn't open LosslessCut: \(message)" }
        }
    }

    func saveCSV() {
        guard let video, !clips.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = video.deletingPathExtension().lastPathComponent + "-clips.csv"
        panel.directoryURL = video.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LosslessCut.csv(for: keptClips.sorted { $0.start < $1.start }, stars: stars)
                .write(to: url, atomically: true, encoding: .utf8)
            markSaved()
            notice = "Saved “\(url.lastPathComponent)”."
        } catch {
            notice = "Couldn't save the file: \(error.localizedDescription)"
        }
    }

    private static var getLosslessCutNotice: String {
        #if arch(arm64)
        let file = "LosslessCut-mac-arm64.dmg"
        #else
        let file = "LosslessCut-mac-x64.dmg"
        #endif
        return "On the page that opened, download \(file), open it and drag LosslessCut into Applications."
    }

    func getLosslessCut() {
        NSWorkspace.shared.open(URL(string: "https://github.com/mifi/lossless-cut/releases/latest")!)
        notice = Self.getLosslessCutNotice
    }

    // MARK: Small conveniences

    func showInFinder() {
        if let video { NSWorkspace.shared.activateFileViewerSelecting([video]) }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func quoted(_ url: URL?) -> String {
        url.map { "“\($0.lastPathComponent)”" } ?? "this recording"
    }

    /// 1 → "1 play", 3 → "3 plays"
    static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}
