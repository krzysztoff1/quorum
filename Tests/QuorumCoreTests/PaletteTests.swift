import XCTest
@testable import QuorumCore

final class PaletteTests: XCTestCase {

    private let now = Clock.date("2026-10-11T14:00:00.000Z")

    private func threads() throws -> [QuestionThread] {
        let personalization = try RunFixture.make(question: "Q1", title: "Personalizacja w food-tech", tier: "deep",
                                                  created: "2026-10-11T09:00:00.000Z", finished: "2026-10-11T09:10:00.000Z")
        let menu = try RunFixture.make(question: "Q2", run: "R2", title: "Ile pozycji w menu cateringu",
                                       created: "2026-10-10T09:00:00.000Z", finished: "2026-10-10T09:10:00.000Z", base: "allergy.run.json")
        let old = try RunFixture.make(question: "Q3", run: "R3", title: "Psychologia menu restauracyjnego", tier: "deep",
                                      created: "2026-09-01T09:00:00.000Z", finished: "2026-09-01T09:10:00.000Z")
        return ThreadIndex.build(runs: [personalization, menu, old])
    }

    private func search(_ query: String, filter: PaletteFilter = .all, selected: String? = nil, canGoDeeper: Bool = false,
                        anyRunning: Bool = false) throws -> [PaletteGroup] {
        let all = try threads()
        let context = PaletteContext(selected: all.first { $0.id == selected }, canGoDeeper: canGoDeeper, anyRunning: anyRunning)
        return Palette.search(query: query, filter: filter, threads: all, context: context, now: now, calendar: Clock.calendar)
    }

    private func group(_ groups: [PaletteGroup], _ section: PaletteSection) -> PaletteGroup? { groups.first { $0.section == section } }

    func testQuestionsAreRankedByWhereTheQueryLandsInTheTitle() throws {
        let groups = try search("menu")
        let titles = group(groups, .questions)?.items.map(\.title)
        XCTAssertEqual(titles, ["Ile pozycji w menu cateringu", "Psychologia menu restauracyjnego"])
    }

    func testAnEmptyQueryListsTheRecentQuestionsInInboxOrderAndTheCommands() throws {
        let groups = try search("")
        XCTAssertEqual(groups.map(\.section), [.questions, .commands])
        XCTAssertEqual(group(groups, .questions)?.items.map(\.title),
                       ["Personalizacja w food-tech", "Ile pozycji w menu cateringu", "Psychologia menu restauracyjnego"])
    }

    func testTheQueryIsAlsoSearchedInsideTheAnswersOfOtherQuestionsWithASnippet() throws {
        let groups = try search("McKinsey")
        let inside = try XCTUnwrap(group(groups, .insideAnswers)?.items.first)
        XCTAssertEqual(inside.title, "Personalizacja w food-tech")
        XCTAssertTrue(try XCTUnwrap(inside.snippet).text.contains("McKinsey"))
        XCTAssertEqual(inside.action, .openQuestion("Q1"))
        XCTAssertNil(group(groups, .questions))
    }

    func testAQuestionMatchedByItsTitleIsNotRepeatedInsideAnswers() throws {
        let groups = try search("Personalizacja")
        XCTAssertEqual(group(groups, .questions)?.items.map(\.title), ["Personalizacja w food-tech"])
        XCTAssertFalse(group(groups, .insideAnswers)?.items.contains { $0.action == .openQuestion("Q1") } ?? false)
    }

    func testSearchIgnoresCaseAndAccents() throws {
        XCTAssertNotNil(group(try search("mckinsey"), .insideAnswers))
        XCTAssertNotNil(group(try search("PERSONALIZACJA"), .questions))
        XCTAssertNotNil(group(try search("pozycjí"), .questions))
    }

    func testSourceQuotesAreSearchableAndOpenThatSource() throws {
        let groups = try search("Store2Vec")
        let source = try XCTUnwrap(group(groups, .sources)?.items.first)
        XCTAssertTrue(try XCTUnwrap(source.snippet).text.contains("Store2Vec"))
        guard case .openSource(let question, _) = source.action else { return XCTFail("not an open-source action") }
        XCTAssertEqual(question, "Q1")
    }

    func testTypingNeverDeadEndsItCanAlwaysBecomeAQuestion() throws {
        let groups = try search("something nobody has written")
        let ask = try XCTUnwrap(group(groups, .ask)?.items.first)
        XCTAssertEqual(ask.action, .askNew("something nobody has written"))
        XCTAssertEqual(ask.title, "Ask “something nobody has written” as a new question")
    }

    func testAFollowUpIsOfferedOnTheOpenQuestion() throws {
        let groups = try search("and what about X", selected: "Q1")
        let items = try XCTUnwrap(group(groups, .ask)?.items)
        XCTAssertEqual(items.map(\.action), [.askNew("and what about X"), .followUp(question: "Q1", text: "and what about X")])
        XCTAssertEqual(items[1].title, "Follow up on Personalizacja w food-tech")
    }

    func testFiltersNarrowTheQuestions() throws {
        XCTAssertEqual(group(try search("", filter: .deep), .questions)?.items.map(\.title),
                       ["Personalizacja w food-tech", "Psychologia menu restauracyjnego"])
        XCTAssertEqual(group(try search("", filter: .thisWeek), .questions)?.items.map(\.title),
                       ["Personalizacja w food-tech", "Ile pozycji w menu cateringu"])
        XCTAssertNil(group(try search("", filter: .running), .questions))
    }

    func testFiltersCycleInOrder() {
        XCTAssertEqual(PaletteFilter.all.next, .running)
        XCTAssertEqual(PaletteFilter.running.next, .deep)
        XCTAssertEqual(PaletteFilter.deep.next, .thisWeek)
        XCTAssertEqual(PaletteFilter.thisWeek.next, .all)
    }

    func testCommandsAreSearchedByTheirNames() throws {
        let commands = try XCTUnwrap(group(try search("brain"), .commands)?.items)
        XCTAssertEqual(commands.map(\.action), [.command(.chooseBrain)])
    }

    func testGoDeeperAndStopOnlyAppearWhenTheyCanDoSomething() throws {
        XCTAssertNil(group(try search("again", selected: "Q1", canGoDeeper: false), .commands))
        let deeper = try XCTUnwrap(group(try search("again", selected: "Q1", canGoDeeper: true), .commands)?.items)
        XCTAssertEqual(deeper.map(\.action), [.command(.goDeeper)])
        XCTAssertNil(group(try search("stop", anyRunning: false), .commands))
        XCTAssertNotNil(group(try search("stop", anyRunning: true), .commands))
    }

    func testCommandsAboutTheOpenQuestionNeedAnOpenQuestion() throws {
        XCTAssertNil(group(try search("copy"), .commands))
        XCTAssertNotNil(group(try search("copy", selected: "Q1"), .commands))
    }

    func testThePreviewShowsTheLeadTheTrustAndTheFollowUps() throws {
        let all = try threads()
        let preview = try XCTUnwrap(Palette.preview(for: .openQuestion("Q1"), threads: all))
        XCTAssertEqual(preview.title, "Personalizacja w food-tech")
        XCTAssertTrue(preview.lead.hasPrefix("Personalization pays in food tech"))
        XCTAssertFalse(preview.lead.contains("[^"))
        XCTAssertEqual(preview.trustLine, "Moderate · 5 of 10 claims solid · 0 conflicts · 9 cited")
        XCTAssertNil(Palette.preview(for: .askNew("x"), threads: all))
    }
}
