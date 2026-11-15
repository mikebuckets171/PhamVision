import PhamVisionCore
import SwiftUI
import UserNotifications

/// Receives recordings opened from Finder, the Dock icon or `open -a`, and
/// checks before quitting would throw away a scan.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: AppModel?
    private var showWindow: (() -> Void)?
    private var pending: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The window is always dark; keep alerts, panels and menus matching.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Temporary MP4 copies of MKV recordings, left over if the app was force-quit.
        Remuxer.removeLeftovers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Remuxer.removeLeftovers()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(url) } else { pending = url }
    }

    /// Called once the window is up.
    func connect(_ model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        if let url = pending {
            pending = nil
            model.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let question = model?.quitConfirmation else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: question.cancel)
        alert.addButton(withTitle: question.confirm).hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        // Closing the window is what got us here; bring it back.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { showWindow?() }
        return .terminateCancel
    }
}

@main
struct PhamVisionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("PhamVision", id: "main") {
            RootView(model: model, delegate: delegate)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recording…") { model.chooseFile() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Get LosslessCut…") { model.getLosslessCut() }
            }
        }
    }
}

private struct RootView: View {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environment(model)
            .frame(minWidth: 760, minHeight: 560)
            .preferredColorScheme(.dark)
            .onAppear {
                let openWindow = openWindow
                delegate.connect(model) { openWindow(id: "main") }
            }
    }
}

enum Brand {
    static let teal = Color(red: 0.18, green: 0.90, blue: 0.71)
    static let orange = Color(red: 0.93, green: 0.45, blue: 0.13)
}

// MARK: - Dock icon progress

/// Draws a progress bar over the Dock icon while a scan runs.
@MainActor
enum DockProgress {
    private static var view: DockProgressView?

    static func show(_ fraction: Double) {
        let tile = NSApp.dockTile
        let view: DockProgressView
        if let existing = Self.view {
            view = existing
        } else {
            view = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            Self.view = view
            tile.contentView = view
            view.fraction = -1
        }
        // Redraw at most once per percent.
        let rounded = (min(max(fraction, 0), 1) * 100).rounded() / 100
        guard rounded != view.fraction else { return }
        view.fraction = rounded
        tile.display()
    }

    static func hide() {
        guard view != nil else { return }
        view = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let width = bounds.width * 0.74
        let height = max(10, bounds.height * 0.12)
        let bar = NSRect(x: (bounds.width - width) / 2, y: bounds.height * 0.1, width: width, height: height)
        NSColor(white: 0.05, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2).fill()
        let inner = bar.insetBy(dx: 2.5, dy: 2.5)
        let filled = NSRect(x: inner.minX, y: inner.minY,
                            width: max(inner.height, inner.width * max(fraction, 0)), height: inner.height)
        NSColor(Brand.teal).setFill()
        NSBezierPath(roundedRect: filled, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}

// MARK: - Finished-scan alerts

/// Lets the user know a long scan has finished, without them watching it.
@MainActor
enum Attention {
    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }
    private static var asked = false

    /// Asks once, the first time a scan starts, so the request makes sense in context.
    static func askPermission() {
        guard canNotify, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A sound if PhamVision is in front (only for scans long enough to walk
    /// away from), otherwise a Dock bounce plus a notification.
    static func finished(title: String, body: String, after seconds: Double) {
        if NSApp.isActive {
            if seconds >= 60 { NSSound(named: "Glass")?.play() }
            return
        }
        NSApp.requestUserAttention(.informationalRequest)
        guard canNotify else {
            NSSound(named: "Glass")?.play()
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            Task { @MainActor in
                guard allowed else {
                    NSSound(named: "Glass")?.play()
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: "scan-finished", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
}
