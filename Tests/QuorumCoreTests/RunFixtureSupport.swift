import Foundation
@testable import QuorumCore

enum RunFixture {
    static func make(question: String = "Q1", run: String = "R1", title: String = "A question",
                     kind: String = "initial", status: String = "complete", tier: String = "quick",
                     trust: String = "moderate", conflicts: Int = 0, created: String = "2026-10-09T10:00:00.000Z",
                     finished: String? = "2026-10-09T10:04:30.000Z", base: String = "personalization.run.json",
                     asked: String? = nil, choices: Int = 0) throws -> StoredRun {
        let data = try Data(contentsOf: EngineFixtures.url("record/\(base)"))
        var record = try XCTUnwrapJSON(data)
        record["id"] = run
        record["question_id"] = question
        record["kind"] = kind
        record["status"] = status
        record["created_at"] = created
        record["updated_at"] = finished ?? created
        record["finished_at"] = finished
        var brief = record["brief"] as? [String: Any] ?? [:]
        brief["tier"] = tier
        brief["title"] = title
        if let asked { brief["asked"] = asked }
        brief["clarifications"] = (0..<choices).map { ["question": "Q\($0)", "answer": "A\($0)"] }
        record["brief"] = brief
        var stats = record["stats"] as? [String: Any] ?? [:]
        stats["trust_level"] = trust
        stats["conflicts_open"] = conflicts
        record["stats"] = stats
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: record))
        let questionJSON = """
        {"schema":"quorum.question/1","id":"\(question)","created_at":"\(created)","original_text":"\(asked ?? title)",
         "resolved_text":"\(title)?","language":"en","title":"\(title)","title_source":"scope","run_ids":["\(run)"]}
        """
        let questionRecord = try JSONDecoder().decode(QuestionRecord.self, from: Data(questionJSON.utf8))
        return StoredRun(runDir: URL(fileURLWithPath: "/tmp/quorum-fixture/questions/\(question)/runs/\(run)"),
                         record: decoded, question: questionRecord)
    }

    private static func XCTUnwrapJSON(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }
}

enum Clock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ iso: String) -> Date { ISO8601DateFormatter.fractional.date(from: iso)! }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
