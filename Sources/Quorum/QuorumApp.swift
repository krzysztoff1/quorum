import SwiftUI
import AppKit
import QuorumCore

struct QuorumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppShell(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ask a Question") { model.dispatch(.newQuestion) }.keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { model.dispatch(.toggleSidebar) }.keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.dispatch(.palette) }.keyboardShortcut("k", modifiers: .command)
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading) {
                Text(model.menuSummary).font(.callout)
                if model.anyRunning { Button("Stop all runs") { model.stopAll() } }
                Divider()
                Button("Quit Quorum") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            Image(systemName: model.anyRunning ? "moon.stars.fill" : "moon.stars")
        }

        Settings { SettingsView(model: model) }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 420)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage("terminalBundleID") private var terminalBundleID = TerminalApp.default.bundleID

    var body: some View {
        Form {
            Section("Brain folder") {
                LabeledContent("Location") { Text(model.brainURL.path).lineLimit(1).truncationMode(.middle) }
                Button("Choose…") { model.chooseBrainFolder() }
            }
            Section("Notifications") {
                Toggle("Notify me when a run finishes", isOn: $model.notifyOnFinish)
            }
            Section("Terminal") {
                Picker("Open sessions in", selection: $terminalBundleID) {
                    ForEach(TerminalApp.installed) { Text($0.name).tag($0.bundleID) }
                }
                Text("Which app “Open in Claude Code” uses.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Engine") {
                Button("Run doctor…") { model.showsDoctor = true }
            }
        }
        .formStyle(.grouped)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum DockStatus {
    static func update(unread: Int) {
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }
}
