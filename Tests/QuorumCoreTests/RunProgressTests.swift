import XCTest
@testable import QuorumCore

final class RunProgressTests: XCTestCase {

    private func progress(_ stage: String, _ index: Int, done: Int = 0, total: Int = 0, sources: Int = 0,
                          eta: Int? = nil) -> RunProgress {
        RunProgress(stage: stage, stageIndex: index, stageCount: 5, tasksDone: done, tasksTotal: total,
                    sourcesRead: sources, etaSeconds: eta)
    }

    func testResearchSaysHowFarTheTasksAreAndHowManySourcesWereRead() {
        XCTAssertEqual(progress("research", 2, done: 1, total: 3, sources: 4).label,
                       "Researching · step 2 of 5 · 1 of 3 tasks · 4 sources read")
    }

    func testEachStageHasItsOwnWord() {
        XCTAssertTrue(progress("draft", 3).label.hasPrefix("Drafting · step 3 of 5"))
        XCTAssertTrue(progress("check", 4).label.hasPrefix("Checking · step 4 of 5"))
        XCTAssertTrue(progress("answer", 5).label.hasPrefix("Finishing · step 5 of 5"))
    }

    func testAStageNobodyKnowsKeepsItsOwnNameRatherThanBlanking() {
        XCTAssertTrue(progress("sharpening", 2).label.hasPrefix("Sharpening · step 2 of 5"))
    }

    func testNothingIsSaidAboutTasksBeforeThereAreAny() {
        XCTAssertEqual(progress("research", 2).label, "Researching · step 2 of 5")
    }

    func testOneSourceIsNotSources() {
        XCTAssertTrue(progress("research", 2, sources: 1).label.hasSuffix("1 source read"))
    }

    func testAnEtaIsRoundedToWholeMinutes() {
        XCTAssertTrue(progress("research", 2, eta: 240).label.hasSuffix("about 4 min left"))
        XCTAssertTrue(progress("research", 2, eta: 20).label.hasSuffix("under a minute left"))
    }
}
