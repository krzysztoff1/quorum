import Foundation

public enum PriorNotes {
    private static let noteLimit = 3
    private static let excerptLength = 1200

    public static func excerpt(_ notes: [URL]) -> String {
        notes.prefix(noteLimit).compactMap { url -> String? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let excerpt = text.count > excerptLength ? String(text.prefix(excerptLength)) + "\n…(truncated)" : text
            return "--- \(url.lastPathComponent) ---\n\(excerpt)"
        }.joined(separator: "\n\n")
    }
}
