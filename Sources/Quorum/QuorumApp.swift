import SwiftUI
import AppKit
import QuorumCore

struct QuorumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Quick Open…") { model.quickSwitchOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        // At-a-glance run status without opening the main window (story 19).
        MenuBarExtra {
            VStack(alignment: .leading) {
                Text(model.activeRuns.isEmpty ? "Idle" : "\(model.activeRuns.count) researching")
                    .font(.callout)
                if model.pendingApprovalCount > 0 {
                    Label("\(model.pendingApprovalCount) waiting on you", systemImage: "hand.raised.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !model.activeRuns.isEmpty {
                    Button("Stop all runs") { model.stopAll() }
                }
                Divider()
                Button("Quit Quorum") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            if model.pendingApprovalCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "hand.raised.fill")
                    Text("\(model.pendingApprovalCount)").monospacedDigit()
                }
            } else if let pct = model.progressPercent {
                HStack(spacing: 3) {
                    Image(systemName: "moon.stars.fill")
                    Text("\(pct)%").monospacedDigit()
                }
            } else {
                Image(systemName: model.overallRunState == .running ? "moon.stars.fill" : "moon.stars")
            }
        }

        Settings { SettingsView() }
    }
}

/// The ⌘, preferences window. General (cross-project) settings live in one tab; a "How to Use" guide in
/// the other. Per-run settings (spend caps, effort, models) stay with the run in Compose.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            BYOKSettings()
                .tabItem { Label("Engine & Keys", systemImage: "key") }
            HowToUseView()
                .tabItem { Label("How to Use", systemImage: "questionmark.circle") }
        }
        .frame(width: 480, height: 560)
    }
}

private struct GeneralSettings: View {
    @AppStorage("terminalBundleID") private var terminalBundleID = TerminalApp.default.bundleID

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Open sessions in", selection: $terminalBundleID) {
                    ForEach(TerminalApp.installed) { Text($0.name).tag($0.bundleID) }
                }
                Text("Which app “Continue in Claude Code” and “Fork” open in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// BYOK settings (PRD 02 R4): provider + search keys stored in the Keychain, and the engine's
/// provider/model ids. The default (no keys) leaves Subscription the only profile — the "no API key"
/// promise holds; adding keys lights up Budget / Full BYOK and own search on the CLI path.
private struct BYOKSettings: View {
    @AppStorage("engineAngleModel") private var angleModel = ""
    @AppStorage("engineSynthesisModel") private var synthModel = ""
    @AppStorage("codexAngleModel") private var codexAngleModel = CodexModel.default.rawValue
    @AppStorage("codexSynthesisModel") private var codexSynthModel = ""
    @AppStorage(ExperimentalProfiles.defaultsKey) private var experimentsEnabled = false
    @State private var values: [String: String] = [:]

    private static let engineModels = [
        "deepseek/deepseek-chat",
        "deepseek/deepseek-reasoner",
        "anthropic/claude-opus-4-8",
        "anthropic/claude-sonnet-5",
        "anthropic/claude-haiku-4-5",
        "anthropic/claude-fable-5",
        "openrouter/deepseek/deepseek-chat",
    ]

    var body: some View {
        Form {
            if experimentsEnabled {
                Section("Engine models") {
                    Picker("Angle model", selection: $angleModel) {
                        ForEach(Self.engineModels, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Synthesis model (Full BYOK)", selection: $synthModel) {
                        Text("Same as angle model").tag("")
                        ForEach(Self.engineModels, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Budget synthesizes on your subscription, so its synthesis model is unused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Codex models") {
                    Picker("Angle model", selection: $codexAngleModel) {
                        ForEach(CodexModel.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Picker("Synthesis model", selection: $codexSynthModel) {
                        Text("Same as angle model").tag("")
                        ForEach(CodexModel.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    Text("The Codex profile runs on your `codex` CLI login — no API key. The run's effort preset maps straight onto the model's reasoning level, clamped to what that model offers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Provider keys") {
                    ForEach(EngineKey.allCases.filter(\.isModelProvider)) { secureRow($0) }
                }
            }
            Section("Search keys") {
                ForEach(EngineKey.allCases.filter(\.isSearch)) { secureRow($0) }
                Text("With a search key set, even Subscription runs route web search through your key (via the bundled engine’s MCP server) instead of Anthropic’s metered WebSearch. No key → built-in WebSearch, unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if angleModel.isEmpty { angleModel = Self.engineModels[0] }   // stored "" matches no Picker tag
            for k in EngineKey.allCases { values[k.rawValue] = Keychain.get(k.rawValue) ?? "" }
        }
    }

    private func secureRow(_ key: EngineKey) -> some View {
        SecureField(key.label, text: Binding(
            get: { values[key.rawValue] ?? "" },
            set: { values[key.rawValue] = $0; Keychain.set(key.rawValue, $0) }
        ))
    }
}

/// A short in-app guide to the core loop — ask a question, review angles, research, and let the brain
/// compound. Cross-references the ⌘K switcher and the run settings so newcomers find them.
private struct HowToUseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Getting started", icon: "play.circle") {
                    step(1, "Choose a project folder — your “brain”, its notes and past runs, lives there.")
                    step(2, "On New run, ask one big question and pick how many angles to explore.")
                    step(3, "Review the planned angles — edit, drop, or add your own. Nothing runs, and nothing is charged, until you approve.")
                    step(4, "Research all angles: blind agents run in parallel, then one synthesis reconciles them into a single answer.")
                }
                group("Your brain compounds", icon: "brain") {
                    bullet("Every run saves a markdown note; a related run extends an existing note instead of duplicating it. Browse them under Notes.")
                    bullet("Notes are plain markdown with [[wikilinks]] between them, so the whole brain carries over when you open the folder in Obsidian.")
                }
                group("Tips", icon: "lightbulb") {
                    bullet("Press ⌘K for the quick switcher — jump to any chat, note, or command.")
                    bullet("Turn on Autoresearch in Run settings to keep digging over deeper rounds until the answer is concrete.")
                    bullet("The effort preset in Run settings sets the spend caps — higher effort consults more sources for more cost.")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func group(_ title: String, icon: String,
                                    @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
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
