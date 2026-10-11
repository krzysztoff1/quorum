import AppKit
import QuorumCore

@MainActor
final class KeyDispatcher {
    private var monitor: Any?
    private weak var model: AppModel?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            return self.handle(event, model: model) ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard let window = event.window, window.identifier?.rawValue == AppShell.windowID else { return false }
        guard let press = Self.press(from: event) else { return false }
        let typing = Self.isTyping(window.firstResponder)
        let context = KeyContext(scope: model.keyScope, typing: typing, composing: Self.isComposing(window.firstResponder))
        guard let command = KeyRouter.command(for: press, in: context) else { return false }
        model.dispatch(command)
        return true
    }

    static func press(from event: NSEvent) -> KeyPress? {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        switch event.keyCode {
        case 36, 76: return KeyPress(.returnKey, modifiers)
        case 53: return KeyPress(.escape, modifiers)
        case 48: return KeyPress(.tab, modifiers)
        case 126: return KeyPress(.up, modifiers)
        case 125: return KeyPress(.down, modifiers)
        default: break
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), let first = characters.first, characters.count == 1 else { return nil }
        return KeyPress(.character(first), modifiers)
    }

    static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? NSTextView)?.hasMarkedText() ?? false
    }

    static func isTyping(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return false }
        return text.isEditable
    }
}
