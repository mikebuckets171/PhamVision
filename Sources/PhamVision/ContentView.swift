import AVKit
import PhamVisionCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .idle:
                DropView()
            case .scanning:
                ScanningView()
            case .done:
                ResultsView()
            case .failed(let failure):
                FailedView(failure: failure)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { acceptDrop($0, into: self.model) }
        .confirmationDialog(
            "Replace the existing LosslessCut clip list?",
            isPresented: Binding(get: { model.pendingOverwrite != nil }, set: { if !$0 { model.pendingOverwrite = nil } }),
            presenting: model.pendingOverwrite
        ) { _ in
            Button("Replace", role: .destructive) {
                model.pendingOverwrite = nil
                model.reviewInLosslessCut(overwrite: true)
            }
            Button("Cancel", role: .cancel) { model.pendingOverwrite = nil }
        } message: { url in
            Text("\(url.lastPathComponent) already exists next to this recording. Replacing it discards any segments you marked in LosslessCut.")
        }
        .background {
            // Kept on a separate view from the dialog above so the two never compete.
            Color.clear.alert(
                model.discardConfirmation?.title ?? "",
                isPresented: Binding(get: { model.pendingDiscard != nil }, set: { if !$0 { model.pendingDiscard = nil } }),
                presenting: model.discardConfirmation
            ) { question in
                Button(question.confirm, role: .destructive) { model.confirmDiscard() }
                Button(question.cancel, role: .cancel) { model.pendingDiscard = nil }
            } message: { question in
                Text(question.message)
            }
        }
    }
}

/// Starts a scan for the first file in a drag.
@MainActor
private func acceptDrop(_ providers: [NSItemProvider], into model: AppModel) -> Bool {
    guard let provider = providers.first else { return false }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in model.open(url) }
    }
    return true
}

// MARK: - Idle

private struct DropView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Brand.teal : .secondary)
                .accessibilityHidden(true)
            Text("Drop a 2K recording here")
                .font(.title2.weight(.semibold))
            Text("PhamVision watches your stat line and marks every play\nwhere your points, rebounds or assists go up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose File…") { model.chooseFile() }
                .controlSize(.large)
                .padding(.top, 4)
            Text("MP4, MOV or MKV recordings from NBA 2K27")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Brand.teal : Color.secondary.opacity(0.35))
                .padding(28)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { acceptDrop($0, into: model) }
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.progress
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(model.video?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.duration > 0 {
                    Text("\(Format.clock(model.duration)) of video")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: progress?.overall ?? 0)
                .tint(Brand.teal)
                .frame(maxWidth: 420)
                .accessibilityLabel("Scan progress")
            Text(stage(progress))
                .monospacedDigit()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timing(progress, now: context.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Button("Choose a Different Recording…") { model.chooseFile() }
                    .help("Picked the wrong file? Choose the right one and PhamVision scans that instead")
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop scanning and go back (Esc)")
            }
            .padding(.top, 6)
            Text("PhamVision keeps your Mac awake while it scans and lets you know when it's done.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(48)
    }

    private func stage(_ progress: AppModel.ScanProgress?) -> String {
        guard let progress else { return "" }
        switch progress.stage {
        case .opening:
            return "Opening the recording…"
        case .converting:
            return "Getting the recording ready… \(Int(progress.stageFraction * 100))%"
        case .reading:
            return "Reading your stat line… \(Int(progress.overall * 100))%"
        case .clocks(let done, let total):
            return "Reading the game clock for each play… \(done) of \(total)"
        }
    }

    private func timing(_ progress: AppModel.ScanProgress?, now: Date) -> String {
        guard let progress else { return " " }
        let elapsed = "\(Format.clock(now.timeIntervalSince(progress.started))) elapsed"
        guard let left = progress.secondsLeft(at: now) else { return elapsed }
        let estimate = left < 60 ? "Less than a minute left" : "About \(Format.rough(left)) left"
        return "\(estimate) · \(elapsed)"
    }
}

// MARK: - Failed

private struct FailedView: View {
    @Environment(AppModel.self) private var model
    let failure: AppModel.Failure

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Brand.orange)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(failure.title)
                    .font(.title3.weight(.semibold))
                if let name = model.video?.lastPathComponent {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(failure.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                if failure.needsConverting {
                    if model.losslessCutURL != nil {
                        Button("Open in LosslessCut") { model.openVideoInLosslessCut() }
                            .help("Open this file in LosslessCut so you can export it as MP4")
                    } else {
                        Button("Get LosslessCut") { model.getLosslessCut() }
                    }
                }
                if failure.canRetry {
                    Button("Try Again") { model.retry() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Try Another File") { model.reset() }
            }
            .padding(.top, 6)
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(48)
    }
}

// MARK: - Results

private struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Clip.ID?
    @State private var previewing: Clip.ID?
    /// What the player steps through: the list, or a single accuracy-check gap.
    @State private var previewClips: [Clip] = []
    @State private var showingAccuracy = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.plays.isEmpty {
                emptyState
            } else {
                controls
                Divider()
                clipList
            }
            Divider()
            footer
        }
        .sheet(isPresented: Binding(get: { previewing != nil }, set: { if !$0 { previewing = nil } })) {
            if let video = model.playable ?? model.video {
                ClipPreview(video: video, clips: previewClips, current: $previewing, selection: $selection)
            }
        }
        .sheet(isPresented: Binding(get: { model.exportProgress != nil }, set: { _ in })) {
            ExportProgressView()
        }
        .sheet(isPresented: $showingAccuracy) {
            AccuracyDetails(watch: watch(gap:in:))
        }
    }

    private func watch(_ id: Clip.ID) {
        previewClips = model.shownClips
        previewing = id
    }

    private func watch(gap: GameSummary.Gap, in game: GameSummary) {
        let clip = model.clip(for: gap, in: game)
        showingAccuracy = false
        previewClips = [clip]
        // Let the details sheet close before the player sheet opens.
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            previewing = clip.id
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.video?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contextMenu {
                        Button("Show in Finder") { model.showInFinder() }
                    }
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !model.gameChecks.isEmpty {
                    accuracyLine
                }
            }
            Spacer()
            Button("Scan Another") { model.startOver() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var summary: String {
        let plays = AppModel.count(model.plays.count, "play")
        let games = AppModel.count(model.games, "game")
        return "\(plays) across \(games) · \(Format.clock(model.duration)) scanned in \(Format.rough(model.scanSeconds))"
    }

    /// "✓ Accuracy check: all 3 games add up" with a Details popover.
    private var accuracyLine: some View {
        let problems = model.gamesWithGaps
        let total = model.gameChecks.count
        let text = problems.isEmpty
            ? (total == 1 ? "Accuracy check: the game adds up" : "Accuracy check: all \(total) games add up")
            : "Accuracy check: \(AppModel.count(problems.count, "game")) of \(total) \(problems.count == 1 ? "has" : "have") stats with no clip"
        return HStack(spacing: 6) {
            Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problems.isEmpty ? Brand.teal : Brand.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
            Button("Details") { showingAccuracy = true }
                .buttonStyle(.link)
                .font(.subheadline)
        }
        .padding(.top, 2)
        .help("Compares the plays PhamVision found with how much your stat line went up in each game")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No plays found")
                .font(.title3.weight(.semibold))
            Text("The stat line never appeared in the top-right corner of this recording.\nPhamVision reads the NBA 2K27 player HUD at its default position.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Filter chips on the left, order and clip length on the right; the
    /// right-hand group drops to its own row when the window is too narrow.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                filterChips
                Spacer(minLength: 12)
                listSettings
            }
            VStack(alignment: .leading, spacing: 10) {
                filterChips
                HStack(spacing: 18) {
                    Spacer()
                    listSettings
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
                ForEach([PlayKind.points, .assist, .rebound, .feed, .others], id: \.self) { kind in
                    let count = model.count(kind)
                    if count > 0 {
                        let on = model.settings.kinds.contains(kind)
                        Button {
                            if on { model.settings.kinds.remove(kind) } else { model.settings.kinds.insert(kind) }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(kind.color).frame(width: 8, height: 8)
                                Text(kind.plural)
                                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(on ? kind.color.opacity(0.22) : Color.clear, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? kind.color.opacity(0.6) : Color.secondary.opacity(0.35)))
                            .opacity(on ? 1 : 0.55)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(on ? "Hide \(kind.plural.lowercased())" : "Show \(kind.plural.lowercased())")
                        .accessibilityLabel("\(kind.plural), \(count)")
                        .accessibilityValue(on ? "Shown" : "Hidden")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
        }
    }

    private var listSettings: some View {
        @Bindable var model = model
        return HStack(spacing: 18) {
            Picker("Order", selection: $model.bestFirst) {
                Text("Recording order").tag(false)
                Text("Best first").tag(true)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .labelsHidden()
            .help("Show clips in the order they happened, or the highest-rated first")
            if !model.usesDefaultClipLength {
                Button {
                    model.resetClipLength()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Back to 12 seconds before and 3 after")
                .accessibilityLabel("Reset clip length to 12 seconds before and 3 after")
            }
            Stepper(value: $model.settings.before, in: AppModel.beforeRange, step: 1) {
                Text("Before \(Int(model.settings.before))s").monospacedDigit()
            }
            .help("Seconds of video kept before each play")
            .accessibilityLabel("Seconds before each play")
            .accessibilityValue("\(Int(model.settings.before))")
            Stepper(value: $model.settings.after, in: AppModel.afterRange, step: 1) {
                Text("After \(Int(model.settings.after))s").monospacedDigit()
            }
            .help("Seconds of video kept after each play")
            .accessibilityLabel("Seconds after each play")
            .accessibilityValue("\(Int(model.settings.after))")
        }
        .fixedSize()
    }

    private var clipList: some View {
        Table(model.shownClips, selection: $selection) {
            TableColumn("Keep") { clip in
                Toggle("Keep", isOn: Binding(get: { model.isKept(clip) }, set: { model.setKept(clip, $0) }))
                    .labelsHidden()
                    .help("Ticked clips are exported, and selected when opened in LosslessCut")
                    .accessibilityLabel("Keep clip at \(Format.clock(clip.start))")
            }
            .width(34)
            TableColumn("Rating") { clip in
                StarsView(count: model.stars[clip.id] ?? 1)
            }
            .width(54)
            TableColumn("Time") { clip in
                Text(Format.clock(clip.start)).monospacedDigit()
            }
            .width(70)
            TableColumn("Game") { clip in
                Text("\(clip.plays.first?.game ?? 1)").monospacedDigit()
            }
            .width(44)
            TableColumn("Clock") { clip in
                Text(clip.plays.first?.clock ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(72)
            TableColumn("Play") { clip in
                HStack(spacing: 6) {
                    ForEach(clip.plays) { play in
                        Text(play.detail)
                            .font(.callout)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(play.kind.color.opacity(0.22), in: Capsule())
                    }
                    if ClipRating.isClutch(clip) {
                        Text("CLUTCH")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.orange)
                            .help("Late in the 4th quarter or overtime with the game close")
                    }
                }
                .opacity(model.isKept(clip) ? 1 : 0.45)
            }
            TableColumn("Length") { clip in
                Text("\(Int(clip.duration.rounded()))s").monospacedDigit()
            }
            .width(56)
        }
        .contextMenu(forSelectionType: Clip.ID.self) { ids in
            if let id = ids.first, let clip = model.clip(id) {
                Button("Watch Clip") { watch(id) }
                Button(model.isKept(clip) ? "Untick" : "Tick") { model.setKept(clip, !model.isKept(clip)) }
                Divider()
                Button("Copy Time (\(Format.clock(clip.start)))") { model.copy(Format.clock(clip.start)) }
                Button("Copy Description") { model.copy(clip.label) }
            }
        } primaryAction: { ids in
            if let id = ids.first { watch(id) }
        }
        .onChange(of: model.clips) {
            // Clip numbers are reassigned when filters or lengths change, so an
            // old selection would point at a different clip.
            selection = nil
        }
        .onKeyPress(.space) {
            guard let selection else { return .ignored }
            watch(selection)
            return .handled
        }
        .overlay {
            if model.clips.isEmpty {
                ContentUnavailableView(
                    "Every kind of play is hidden",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Click Points, Assists, Rebounds or Highlights above to show those clips again.")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tickedSummary)
                    .monospacedDigit()
                Text(model.notice ?? (model.clips.isEmpty ? " " : "Double-click a clip to watch it. Untick any you don't want."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu("Tick") {
                Button("Tick All") { model.keepOnly(minStars: 1) }
                Button("Tick ★★ and Up Only") { model.keepOnly(minStars: 2) }
                Button("Tick ★★★ Only") { model.keepOnly(minStars: 3) }
                Divider()
                Button("Untick All") { model.untickAll() }
            }
            .fixedSize()
            .disabled(model.clips.isEmpty)
            .help("Choose which clips to keep by rating")
            Menu("More") {
                Button("Review in LosslessCut") { model.reviewInLosslessCut() }
                    .disabled(model.clips.isEmpty)
                if model.losslessCutURL == nil {
                    Button("Get LosslessCut…") { model.getLosslessCut() }
                }
                Divider()
                Button("Export One Highlight Reel…") { model.exportReel() }
                    .disabled(model.keptClips.isEmpty)
                Button("Save Clip List as CSV…") { model.saveCSV() }
                    .disabled(model.keptClips.isEmpty)
            }
            .fixedSize()
            .help("A single highlight reel, fine-tuning in LosslessCut, or the clip list as a spreadsheet")
            Button("Save CSV") { model.saveCSV() }
                .keyboardShortcut("s")
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            Button("Export for TikTok…") { model.exportVertical() }
                .disabled(model.keptClips.isEmpty)
                .help("Make a vertical 1080×1920 video of each ticked clip, with a caption, ready for TikTok, Reels or Shorts")
            Button("Export Clips…") { model.exportClips() }
                .buttonStyle(.borderedProminent)
                .tint(Brand.teal)
                .foregroundStyle(.black)
                .keyboardShortcut(.defaultAction)
                .disabled(model.keptClips.isEmpty)
                .help("Save each ticked clip as its own MP4, at full quality")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

extension ResultsView {
    fileprivate var tickedSummary: String {
        let total = model.clips.count
        let ticked = model.keptClips.count
        let length = Format.clock(model.keptSeconds)
        if ticked == total { return "\(AppModel.count(total, "clip")) · \(length) of footage" }
        return "\(ticked) of \(AppModel.count(total, "clip")) ticked · \(length) of footage"
    }
}

// MARK: - Ratings, accuracy and export progress

/// One to three stars.
private struct StarsView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(i < count ? Brand.orange : Color.secondary.opacity(0.4))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(count) of 3 stars")
        .help(count == 3 ? "One of the best clips in this recording" : count == 2 ? "A good clip" : "A routine play")
    }
}

/// Each game's plays compared with how much its stat line went up.
private struct AccuracyDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let watch: (GameSummary.Gap, GameSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accuracy check")
                .font(.title3.weight(.semibold))
            Text("For each game, PhamVision adds up the plays it found and compares the total with how much your stat line went up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.gameChecks, id: \.index) { game in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: game.checksOut ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(game.checksOut ? Brand.teal : Brand.orange)
                            .accessibilityHidden(true)
                        Text(game.title).font(.subheadline.weight(.semibold))
                        Text(totals(game))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(problems(game), id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(game.gaps.enumerated()), id: \.offset) { _, gap in
                        HStack {
                            Text("\(gap.unit) went from \(gap.from) to \(gap.to) between \(Format.clock(gap.after)) and \(Format.clock(gap.before)), while the stat line was hidden.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Watch") { watch(gap, game) }
                        }
                    }
                }
            }
            Text("Steals and blocks come from the event feed, so they aren't part of this check.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    /// "35 PTS · 3 REB · 14 AST"
    private func totals(_ game: GameSummary) -> String {
        game.stats.map { "\($0.expected) \($0.unit)" }.joined(separator: " · ")
    }

    private func problems(_ game: GameSummary) -> [String] {
        game.stats.compactMap { stat in
            if stat.missing > 0 {
                return "\(stat.missing) of \(stat.expected) \(stat.unit) didn't become a clip."
            }
            if stat.missing < 0 {
                return "PhamVision found \(-stat.missing) more \(stat.unit) than the stat line went up, so a clip may be listed twice."
            }
            return nil
        }
    }
}

/// Shown while clips are being saved.
private struct ExportProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Text(model.exportTitle)
                .font(.headline)
            ProgressView(value: model.exportProgress ?? 0)
                .tint(Brand.teal)
                .frame(width: 320)
                .accessibilityLabel("Export progress")
            Text("\(Int(((model.exportProgress ?? 0) * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Stop") { model.cancelExport() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .interactiveDismissDisabled()
    }
}

// MARK: - Watching a clip

/// Plays one clip of the recording, with buttons to step through the rest.
private struct ClipPreview: View {
    let video: URL
    let clips: [Clip]
    @Binding var current: Clip.ID?
    @Binding var selection: Clip.ID?
    @State private var player: ClipPlayer?
    @Environment(\.dismiss) private var dismiss

    private var index: Int? { clips.firstIndex { $0.id == current } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let player {
                    PlayerView(player: player.player)
                } else {
                    Color.black
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 405)
            Divider()
            HStack(spacing: 10) {
                if let index {
                    let clip = clips[index]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.label)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Clip \(index + 1) of \(clips.count) · starts at \(Format.clock(clip.start)) · \(Int(clip.duration.rounded())) seconds")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button("Previous") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled((index ?? 0) == 0)
                    .help("Previous clip (←)")
                Button("Replay") { if let index { player?.play(clips[index]) } }
                    .help("Play this clip again from the start")
                Button("Next") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled((index ?? clips.count) >= clips.count - 1)
                    .help("Next clip (→)")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .onAppear {
            let player = ClipPlayer(url: video)
            self.player = player
            if let index { player.play(clips[index]) }
        }
        .onChange(of: current) {
            if let index {
                selection = clips[index].id
                player?.play(clips[index])
            }
        }
        .onDisappear { player?.stop() }
    }

    private func step(_ by: Int) {
        guard let index, clips.indices.contains(index + by) else { return }
        current = clips[index + by].id
    }
}

/// Plays a stretch of the recording and pauses at its end.
@MainActor
private final class ClipPlayer {
    let player: AVPlayer
    private var endObserver: Any?
    private var seek: Task<Void, Never>?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
    }

    func play(_ clip: Clip) {
        player.pause()
        removeEndObserver()
        let end = CMTime(seconds: clip.end, preferredTimescale: 600)
        endObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.player.pause() }
        }
        seek?.cancel()
        let player = player
        seek = Task {
            let start = CMTime(seconds: clip.start, preferredTimescale: 600)
            let finished = await player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            guard finished, !Task.isCancelled else { return }
            player.play()
        }
    }

    func stop() {
        seek?.cancel()
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func removeEndObserver() {
        if let endObserver { player.removeTimeObserver(endObserver) }
        endObserver = nil
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Helpers

extension PlayKind {
    var plural: String {
        switch self {
        case .points: return "Points"
        case .assist: return "Assists"
        case .rebound: return "Rebounds"
        case .feed: return "Highlights"
        case .others: return "Others"
        }
    }

    var color: Color {
        switch self {
        case .points: return Brand.orange
        case .assist: return Brand.teal
        case .rebound: return .blue
        case .feed: return .purple
        case .others: return .gray
        }
    }
}

enum Format {
    /// 3725 → "1:02:05", 125 → "2:05"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 40 → "40 sec", 95 → "2 min", 5400 → "1 hr 30 min"
    static func rough(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "a while" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) sec" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }
}
