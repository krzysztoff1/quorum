import SwiftUI
import AppKit

/// The canvas's hands. SwiftUI has no scroll-wheel or pinch events of its own on macOS, so a local event
/// monitor catches them for whatever region this view is laid out over: two fingers pan, a pinch or a
/// ⌘-scroll zooms about the cursor. Anything over a real scroll view — the prose inside an opened card —
/// is left alone, because stealing a reader's scroll is worse than having none.
struct PanZoomCatcher: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onWheelZoom: (CGFloat, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        update(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { update(view) }

    private func update(_ view: CatcherView) {
        view.onPan = onPan
        view.onWheelZoom = onWheelZoom
        view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onWheelZoom: ((CGFloat, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?

        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
                [weak self] event in
                self?.handle(event) ?? event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return event }
            switch event.type {
            case .magnify:
                onMagnify?(1 + event.magnification, location)
                return nil
            case .scrollWheel:
                guard !overANestedScroller(event) else { return event }
                if event.modifierFlags.intersection([.command, .control]).isEmpty {
                    onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                } else {
                    onWheelZoom?(event.scrollingDeltaY, location)
                }
                return nil
            default:
                return event
            }
        }

        private func overANestedScroller(_ event: NSEvent) -> Bool {
            guard let content = window?.contentView else { return false }
            var view = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let current = view {
                if current is NSScrollView { return true }
                view = current.superview
            }
            return false
        }
    }
}
