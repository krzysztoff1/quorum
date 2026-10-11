import SwiftUI
import AppKit
import QuorumCore

struct AppShell: View {
    static let windowID = "quorum.main"
    @Bindable var model: AppModel
    @State private var dispatcher = KeyDispatcher()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarVisible { Sidebar(model: model).transition(.move(edge: .leading)) }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.paletteOpen { PaletteView(model: model) }
        }
        .environment(\.shellChrome, model.sidebarVisible ? ShellChrome() : ShellChrome(leadingInset: 64, revealSidebar: { model.dispatch(.toggleSidebar) }))
        .animation(Motion.panel, value: model.sidebarVisible)
        .animation(Motion.reveal, value: model.paletteOpen)
        .background(Ink.ink0)
        .background(WindowConfigurator())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $model.showsDoctor) { DoctorView(model: model) }
        .onAppear {
            dispatcher.install(model: model)
            model.start()
            if AppShot.current.isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AppShot.current.apply(to: model)
                    AppShot.current.scheduleShot()
                }
            }
        }
        .onChange(of: model.unreadCount) { _, _ in DockStatus.update(unread: model.unreadCount) }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .new: NewQuestionView(model: model)
        case .question(let id):
            if let thread = model.thread(id) { ThreadView(model: model, thread: thread).id(id) }
            else { NewQuestionView(model: model) }
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(AppShell.windowID)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(Ink.ink0)
            window.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
