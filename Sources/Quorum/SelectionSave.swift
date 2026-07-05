import SwiftUI
import AppKit

/// A floating "Save" button that pops up over a text selection in a note/writeup, so keeping a snippet is
/// one click at the spot you're reading (matches the highlight-to-save gesture). Driven by
/// `NSTextView.didChangeSelectionNotification` — the note editor and read-only writeups are TextKit views —
/// and positioned at the selection via `firstRect`. It only appears while a research note is open
/// (`AppModel.currentNotePath`), so a saved snippet always links back to its `.md`.
/// ponytail: the bubble follows selection changes, not scrolling — scroll with text selected and it stays
/// put until the next selection change. Track the scroll view's bounds notification if that ever bites.
@MainActor
final class SelectionSaveController {
    static let shared = SelectionSaveController()
    weak var model: AppModel?

    private var panel: NSPanel?
    private weak var textView: NSTextView?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                SelectionSaveController.shared.selectionChanged(note.object as? NSTextView)
            }
        }
    }

    private func selectionChanged(_ tv: NSTextView?) {
        // `!isFieldEditor` keeps this off text inputs (chat box, search, rename) — only note/writeup content.
        guard let tv, !tv.isFieldEditor, tv.window != nil, tv.selectedRange().length > 0,
              model?.currentNotePath != nil else { hide(); return }
        textView = tv
        present(over: tv)
    }

    private func present(over tv: NSTextView) {
        let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
        guard rect.width > 0 || rect.height > 0 else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(NSPoint(x: rect.minX, y: rect.maxY + 6))   // just above the selection's first line
        if panel.parent == nil { tv.window?.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: SaveBubble { [weak self] in self?.save() })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // the SwiftUI capsule draws its own shadow; a window shadow would box it
        panel.contentView = host
        return panel
    }

    private func save() {
        guard let tv = textView, let model, let source = model.currentNotePath else { return }
        model.saveKeeper(text: (tv.string as NSString).substring(with: tv.selectedRange()), source: source)
        hide()
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

private struct SaveBubble: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Save", systemImage: "bookmark.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(6)
    }
}
