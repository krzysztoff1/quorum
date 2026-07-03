import SwiftUI
import AppKit
import QuorumCore

@main
struct QuorumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)

        // At-a-glance run status without opening the main window (story 19).
        MenuBarExtra {
            VStack(alignment: .leading) {
                Text(model.activeRuns.isEmpty
                     ? (model.draftRun?.fanOut.phase == .planning ? "Planning…" : "Idle")
                     : "\(model.activeRuns.count) researching")
                    .font(.callout)
                if !model.activeRuns.isEmpty {
                    Button("Stop all runs") { model.stopAll() }
                }
                Divider()
                Button("Quit Quorum") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            if let pct = model.progressPercent {
                HStack(spacing: 3) {
                    Image(systemName: "moon.stars.fill")
                    Text("\(pct)%").monospacedDigit()
                }
            } else {
                Image(systemName: model.overallRunState == .running ? "moon.stars.fill" : "moon.stars")
            }
        }
    }
}

// Dev launch is unbundled, so macOS shows a generic Dock icon. Set ours at runtime from
// the embedded PNG. ponytail: a shipped .app carries AppIcon.icns in its bundle instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    /// The "✓" done-badge has done its job once you're back looking at the app. Leaves a running
    /// badge ("•"/"2/4") alone — activating mid-run shouldn't clear live progress.
    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.dockTile.badgeLabel == "✓" { NSApp.dockTile.badgeLabel = nil }
    }
}

/// Reflect the run on the Dock icon with the native affordances (no custom drawing): a progress badge
/// while running, a "✓" + one bounce when it finishes (persists overnight, cleared on return above).
enum DockStatus {
    static func update(runState: RunState, progress: String?) {
        switch runState {
        case .idle:
            NSApp.dockTile.badgeLabel = nil
        case .running:
            NSApp.dockTile.badgeLabel = fraction(progress) ?? "•"
        case .finished:
            // Already looking at it → no badge to chase. Otherwise leave a "✓" (cleared on return,
            // so it survives an overnight run) and bounce once now.
            if NSApp.isActive {
                NSApp.dockTile.badgeLabel = nil
            } else {
                NSApp.dockTile.badgeLabel = "✓"
                _ = NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    /// "2/4: topic" → "2/4" for the badge; nil for the non-fraction progress strings ("synthesizing…").
    private static func fraction(_ p: String?) -> String? {
        guard let head = p?.split(separator: ":").first.map(String.init),
              head.contains("/"), head.allSatisfy({ $0.isNumber || $0 == "/" }) else { return nil }
        return head
    }
}
