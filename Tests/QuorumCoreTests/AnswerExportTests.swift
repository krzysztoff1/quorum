import XCTest
@testable import QuorumCore

final class AnswerExportTests: XCTestCase {

    private func brain(withAnswers names: [String]) throws -> URL {
        let brain = try makeTempProject()
        let answers = brain.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        for name in names { try Data("# a".utf8).write(to: answers.appendingPathComponent(name)) }
        return brain
    }

    func testTheExportOfAQuestionEndsWithTheLastFiveCharactersOfItsId() throws {
        let brain = try brain(withAnswers: ["how-large-are-the-advertising-r7j2f.md", "other-thing-zzzzz.md"])
        let found = AnswerExport.url(forQuestion: "01M4HGDDBQX6VS9N0VZP2R7J2F", in: brain)
        XCTAssertEqual(found?.lastPathComponent, "how-large-are-the-advertising-r7j2f.md")
    }

    func testAQuestionWithNoExportHasNone() throws {
        let brain = try brain(withAnswers: ["other-thing-zzzzz.md"])
        XCTAssertNil(AnswerExport.url(forQuestion: "01M4HGDDBQX6VS9N0VZP2R7J2F", in: brain))
        XCTAssertNil(AnswerExport.url(forQuestion: "01M4HGDDBQX6VS9N0VZP2R7J2F", in: try makeTempProject()))
    }
}
