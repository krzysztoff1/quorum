import AppKit
import CoreGraphics
import Foundation

struct DirectorArguments {
    let processID: pid_t
    let script: String
    let track: String
    let marks: String
    let hardware: Bool

    init(_ arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        processID = pid_t(value("--pid") ?? "") ?? 0
        script = value("--script") ?? "script.txt"
        track = value("--track") ?? "cursor.csv"
        marks = value("--marks") ?? "marks.csv"
        hardware = arguments.contains("--hardware")
    }
}

enum Easing {
    static func smooth(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}

enum KeyCodes {
    static let table: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49, "esc": 53, "delete": 51,
        "[": 33, "]": 30, "\\": 42, ",": 43, ".": 47, "up": 126, "down": 125, "left": 123, "right": 124,
    ]
    static let punctuation: [Character: (CGKeyCode, Bool)] = [
        " ": (49, false), ",": (43, false), ".": (47, false), "/": (44, false), "?": (44, true), "'": (39, false),
        "-": (27, false), ";": (41, false), ":": (41, true),
    ]
    static func typing(_ character: Character) -> (CGKeyCode, Bool)? {
        if let entry = punctuation[character] { return entry }
        let lowered = String(character).lowercased()
        guard let code = table[lowered], lowered.count == 1 else { return nil }
        return (code, character.isUppercase)
    }
    static let modifiers: [String: CGEventFlags] = ["cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate, "ctrl": .maskControl]
}

final class Director {
    private let arguments: DirectorArguments
    private var cursor = CGPoint(x: 0, y: 0)
    private var pressed = false
    private var origin = CGPoint.zero
    private var track: FileHandle
    private var marks: FileHandle
    private var typingSeed: UInt64 = 0x9E3779B97F4A7C15
    private var curveSign: CGFloat = 1

    init(_ arguments: DirectorArguments) {
        self.arguments = arguments
        if !FileManager.default.fileExists(atPath: arguments.track) { FileManager.default.createFile(atPath: arguments.track, contents: nil) }
        if !FileManager.default.fileExists(atPath: arguments.marks) { FileManager.default.createFile(atPath: arguments.marks, contents: nil) }
        track = FileHandle(forWritingAtPath: arguments.track)!
        track.seekToEndOfFile()
        marks = FileHandle(forWritingAtPath: arguments.marks)!
        marks.seekToEndOfFile()
        locateWindow()
    }

    private func locateWindow() {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = list.compactMap { entry -> CGRect? in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == arguments.processID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
        origin = owned.max(by: { $0.width * $0.height < $1.width * $1.height })?.origin ?? .zero
        cursor = lastLoggedCursor() ?? CGPoint(x: 720, y: 450)
    }

    private func lastLoggedCursor() -> CGPoint? {
        guard let content = try? String(contentsOfFile: arguments.track, encoding: .utf8),
              let line = content.split(separator: "\n").last else { return nil }
        let fields = line.split(separator: ",").compactMap { Double($0) }
        return fields.count >= 3 ? CGPoint(x: fields[1], y: fields[2]) : nil
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func nextRandom() -> Double {
        typingSeed = typingSeed &* 6364136223846793005 &+ 1442695040888963407
        return Double(typingSeed >> 33) / Double(1 << 31)
    }

    private func logCursor() {
        track.write(Data(String(format: "%.4f,%.1f,%.1f,%d\n", now(), cursor.x, cursor.y, pressed ? 1 : 0).utf8))
    }

    private func globalPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x, y: origin.y + point.y) }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        if arguments.hardware { event.post(tap: .cghidEventTap) } else { event.postToPid(arguments.processID) }
    }

    private func requireFocus() {
        guard arguments.hardware, !quorumIsFrontmost else { return }
        fputs("Quorum lost focus, stopping\n", stderr)
        exit(2)
    }

    private var quorumIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == arguments.processID
    }

    private func postMouse(_ type: CGEventType) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: globalPoint(cursor), mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        post(event)
    }

    func activate() {
        NSRunningApplication(processIdentifier: arguments.processID)?.activate()
        sleep(0.6)
        postMouse(.mouseMoved)
        logCursor()
    }

    func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func move(to target: CGPoint, duration: Double) {
        requireFocus()
        let start = cursor
        let dx = target.x - start.x
        let dy = target.y - start.y
        let distance = max(1, (dx * dx + dy * dy).squareRoot())
        curveSign = -curveSign
        let bend = distance * 0.10 * curveSign
        let control = CGPoint(x: (start.x + target.x) / 2 - dy / distance * bend, y: (start.y + target.y) / 2 + dx / distance * bend)
        let begin = now()
        let interval = 1.0 / 120.0
        var tick = 0
        while true {
            let elapsed = now() - begin
            let linear = min(1, elapsed / duration)
            let t = Easing.smooth(linear)
            let inverse = 1 - t
            cursor = CGPoint(
                x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * target.x,
                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * target.y)
            postMouse(pressed ? .leftMouseDragged : .mouseMoved)
            logCursor()
            if linear >= 1 { break }
            tick += 1
            let nextDeadline = begin + Double(tick) * interval
            let wait = nextDeadline - now()
            if wait > 0 { sleep(wait) }
        }
    }

    func scroll(by totalPixels: Double, duration: Double) {
        requireFocus()
        let begin = now()
        var emitted = 0.0
        while true {
            let linear = min(1, (now() - begin) / duration)
            let target = totalPixels * Easing.smooth(linear)
            let delta = Int32((target - emitted).rounded())
            if delta != 0 {
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                emitted += Double(delta)
            }
            logCursor()
            if linear >= 1 { break }
            sleep(1.0 / 120.0)
        }
    }

    func click() {
        requireFocus()
        pressed = true
        postMouse(.leftMouseDown)
        logCursor()
        sleep(0.09)
        pressed = false
        postMouse(.leftMouseUp)
        logCursor()
    }

    func key(_ combination: String) {
        requireFocus()
        var parts = combination.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let name = parts.removeLast()
        var flags: CGEventFlags = []
        for part in parts { if let flag = KeyCodes.modifiers[part] { flags.insert(flag) } }
        guard let code = KeyCodes.table[name] else { fputs("unknown key \(name)\n", stderr); return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            post(event)
            sleep(0.04)
        }
    }

    func type(_ text: String) {
        requireFocus()
        for character in text {
            if arguments.hardware, let (code, shifted) = KeyCodes.typing(character) {
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                    event?.flags = shifted ? .maskShift : []
                    event?.post(tap: .cghidEventTap)
                    sleep(0.012)
                }
                var pause = 0.045 + nextRandom() * 0.05
                if character == " " { pause += 0.02 }
                if ",.?".contains(character) { pause += 0.12 }
                sleep(pause)
                continue
            }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
                sleep(0.012)
            }
            var pause = 0.045 + nextRandom() * 0.05
            if character == " " { pause += 0.02 }
            if ",.?".contains(character) { pause += 0.12 }
            sleep(pause)
        }
    }

    func mark(_ label: String) {
        marks.write(Data(String(format: "%.4f,%@\n", now(), label).utf8))
    }

    func waitForFile(_ path: String, containing text: String, timeout: Double) {
        let deadline = now() + timeout
        while now() < deadline {
            if let content = try? String(contentsOfFile: path, encoding: .utf8), content.contains(text) { return }
            sleep(1)
        }
        fputs("timeout waiting for \(text) in \(path)\n", stderr)
    }

    func hold(for seconds: Double) {
        let end = now() + seconds
        while now() < end {
            logCursor()
            sleep(min(0.25, max(0.01, end - now())))
        }
    }

    func run() {
        let lines = (try? String(contentsOfFile: arguments.script, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        for line in lines where !line.hasPrefix("#") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            let command = fields[0]
            let rest = fields.count > 1 ? fields[1] : ""
            let numbers = rest.split(separator: " ").compactMap { Double($0) }
            switch command {
            case "activate": activate()
            case "wait": hold(for: numbers.first ?? 1)
            case "key": key(rest)
            case "type": type(rest)
            case "move": move(to: CGPoint(x: numbers[0], y: numbers[1]), duration: numbers.count > 2 ? numbers[2] : 0.8)
            case "click": click()
            case "scroll": scroll(by: numbers[0], duration: numbers.count > 1 ? numbers[1] : 1.2)
            case "mark": mark(rest)
            case "waitfile":
                let parts = rest.components(separatedBy: "|")
                waitForFile(parts[0], containing: parts[1], timeout: Double(parts[2]) ?? 600)
            default: fputs("unknown command \(command)\n", stderr)
            }
        }
        logCursor()
    }
}

_ = NSApplication.shared
Director(DirectorArguments(CommandLine.arguments)).run()
