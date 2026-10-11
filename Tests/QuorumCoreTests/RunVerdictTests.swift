import XCTest
@testable import QuorumCore

final class RunVerdictTests: XCTestCase {

    func testAnAnswerWithAnOpenConflictNamesTheTrustAndTheConflict() throws {
        let run = try RunFixture.make(trust: "moderate", conflicts: 1)
        let sentence = RunVerdict.sentence(for: run)
        XCTAssertTrue(sentence.hasPrefix("Moderate confidence. 1 open conflict"), sentence)
    }

    func testAnAnswerWithoutConflictsSaysHowManySourcesBackIt() throws {
        let run = try RunFixture.make(trust: "solid", conflicts: 0)
        XCTAssertEqual(RunVerdict.sentence(for: run), "Solid confidence. 9 sources cited.")
    }

    func testUncheckedAnswersSayTheQuotesWereNotChecked() throws {
        let run = try RunFixture.make(trust: "unchecked", conflicts: 0)
        XCTAssertEqual(RunVerdict.sentence(for: run), "Quotes not checked. 28 sources read.")
    }

    func testAFailedStoppedOrPartialRunSaysSoInPlainWords() throws {
        XCTAssertEqual(RunVerdict.sentence(for: try RunFixture.make(status: "failed")), "Couldn't finish.")
        XCTAssertEqual(RunVerdict.sentence(for: try RunFixture.make(status: "halted")), "Stopped before it finished.")
        XCTAssertEqual(RunVerdict.sentence(for: try RunFixture.make(status: "partial")), "Partial answer, not fully checked.")
    }

    func testTheNotificationTitleIsTheQuestionsTitle() throws {
        XCTAssertEqual(RunVerdict.title(for: try RunFixture.make(title: "Bun vs Node")), "Bun vs Node")
    }
}
