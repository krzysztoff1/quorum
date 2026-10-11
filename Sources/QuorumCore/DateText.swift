import Foundation

enum DateText {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func string(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let key = "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        let formatter = formatters[key] ?? {
            let made = DateFormatter()
            made.calendar = calendar
            made.timeZone = calendar.timeZone
            made.locale = Locale(identifier: "en_GB")
            made.dateFormat = pattern
            formatters[key] = made
            return made
        }()
        return formatter.string(from: date)
    }
}
