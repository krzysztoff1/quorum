import XCTest
@testable import QuorumCore

final class RunTitleTests: XCTestCase {

    private let question = "Zrób reaserch systemów personalizacji w food tech"

    func testKeepsATitleTheModelActuallyWrote() {
        XCTAssertEqual(RunTitle.from(reply: "Food Tech Personalization Systems", question: question),
                       "Food Tech Personalization Systems")
        XCTAssertEqual(RunTitle.from(reply: "Title: \"Vector DBs Compared\"", question: question),
                       "Vector DBs Compared")
    }

    func testClarifierReplyIsNotATitle() {
        let clarifier = """
        Zanim zacznę deep research, chciałbym sprecyzować zakres — podaj proszę rynek i horyzont czasowy.

        1. Jaki rynek?
        2. Jaki horyzont?
        """
        XCTAssertEqual(RunTitle.from(reply: clarifier, question: question), question)
    }

    func testRefusalAndTypoRepliesAreNotTitles() {
        XCTAssertEqual(RunTitle.from(reply: "I'm not sure what you're looking for — can you say more?",
                                     question: question), question)
        XCTAssertEqual(RunTitle.from(reply: "That looks like a typo! Did you mean \"research\"?",
                                     question: question), question)
    }

    func testAQuestionIsNotATitle() {
        XCTAssertEqual(RunTitle.from(reply: "Which Market Should I Cover?", question: question), question)
    }

    func testMissingReplyFallsBackToTheQuestion() {
        XCTAssertEqual(RunTitle.from(reply: nil, question: question), question)
        XCTAssertEqual(RunTitle.from(reply: "   \n  ", question: question), question)
    }

    func testFallbackCutsALongQuestionOnAWordBoundary() {
        let long = "How do modern food delivery platforms build real-time personalization systems "
                 + "across recommendation, pricing and search surfaces"
        let title = RunTitle.from(reply: nil, question: long)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertTrue(long.hasPrefix(title), "the fallback is a prefix of the question, not a re-write")
        XCTAssertFalse(title.hasSuffix(" "))
        XCTAssertTrue(long.dropFirst(title.count).first == " ", "cut on a word boundary")
    }

    func testFallbackCollapsesWhitespaceAndSurvivesAnUnusableQuestion() {
        XCTAssertEqual(RunTitle.from(reply: nil, question: "  multi\n  line   question  "),
                       "multi line question")
        XCTAssertEqual(RunTitle.from(reply: nil, question: "?!"), "")
    }

    func testAVerboseReplyIsNotATitleEvenOnOneLine() {
        let verbose = "Sure — here is a title you could use for this research question about food tech"
        XCTAssertEqual(RunTitle.from(reply: verbose, question: question), question)
    }
}
