import Foundation

public enum AnswerExport {
    public static func url(forQuestion questionID: String, in brain: URL) -> URL? {
        urls(forQuestion: questionID, in: brain).first
    }

    public static func urls(forQuestion questionID: String, in brain: URL) -> [URL] {
        let tail = "-" + questionID.suffix(5).lowercased()
        let answers = brain.appendingPathComponent("answers", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: answers, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && $0.deletingPathExtension().lastPathComponent.hasSuffix(tail) }
    }
}
