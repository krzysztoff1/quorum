import SwiftUI
import AppKit
import QuorumCore

@MainActor
enum AnswerRender {
    struct Options {
        var hover: String?
        var peek: String?
        var row: String?
        var opened: String?
        var tables: Set<String> = []
        var width: CGFloat = 1440
    }

    static func run(at path: URL) -> StoredRun? {
        let directory = path.hasDirectoryPath ? path : path.deletingLastPathComponent()
        if let stored = StoredRun.load(directory) { return stored }
        guard let data = try? Data(contentsOf: path.hasDirectoryPath ? path.appendingPathComponent(StoredRun.recordFile) : path),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data) else { return nil }
        return StoredRun(runDir: directory, record: record)
    }

    static func write(record path: URL, to output: String, options: Options) -> Bool {
        guard let run = run(at: path), let context = AnswerContext(run: run) else {
            FileHandle.standardError.write(Data("no readable answer in \(path.path)\n".utf8))
            return false
        }
        let focus = AnswerFocus(hot: options.hover, opened: options.opened, tables: options.tables, peek: options.peek)
        if let row = options.row, let found = context.page.figureRow(row) {
            focus.hotRow = row
            focus.hotCites = Set(found.value.cites)
        }
        let view = AnswerScreen(context: context, focus: focus, meta: AnswerContext.meta(run),
                                evidenceDirectory: run.evidenceDirectory, scrolls: false)
            .frame(width: options.width)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: options.width, height: 100)
        let height = max(host.fittingSize.height, 400)
        host.frame = NSRect(x: 0, y: 0, width: options.width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: output))) != nil
    }

    static func options(from arguments: [String]) -> Options {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        var options = Options()
        options.hover = value("--hover")
        options.peek = value("--peek")
        options.row = value("--row")
        options.opened = value("--open")
        options.tables = Set((value("--table") ?? "").split(separator: ",").map(String.init))
        if let width = value("--width").flatMap(Double.init) { options.width = width }
        return options
    }
}
