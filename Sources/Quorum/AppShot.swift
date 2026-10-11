import AppKit
import QuorumCore

struct AppShot {
    let runID: String?
    let opensAnswer: Bool
    let peek: String?
    let charts: Set<String>
    let output: String?
    let delay: TimeInterval

    static let current = AppShot(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        runID = value("--open-run")
        opensAnswer = arguments.contains("--open-answer")
        peek = value("--peek")
        charts = Set((value("--chart") ?? "").split(separator: ",").map(String.init))
        output = value("--shoot")
        delay = value("--shoot-after").flatMap(Double.init) ?? 6
    }

    @MainActor
    func scheduleShot() {
        guard let output else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let written = Self.write(to: output)
            FileHandle.standardError.write(Data((written ? "wrote \(output)\n" : "could not write \(output)\n").utf8))
            NSApp.terminate(nil)
        }
    }

    @MainActor
    static func write(to output: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: output))) != nil
    }
}
