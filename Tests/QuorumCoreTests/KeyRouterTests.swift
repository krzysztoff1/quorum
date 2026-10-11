import XCTest
@testable import QuorumCore

final class KeyRouterTests: XCTestCase {

    private func route(_ key: Key, _ modifiers: KeyModifiers = [], scope: KeyScope = .list, typing: Bool = false) -> AppCommand? {
        KeyRouter.command(for: KeyPress(key, modifiers), in: KeyContext(scope: scope, typing: typing))
    }

    func testCommandKOpensThePaletteFromAnywhereEvenWhileTyping() {
        for scope in [KeyScope.list, .composer, .question(railOpen: false), .scoping(.confirming)] {
            XCTAssertEqual(route(.character("k"), .command, scope: scope, typing: true), .palette)
        }
    }

    func testThePaletteOwnsEveryOtherKeyWhileItIsOpen() {
        XCTAssertNil(route(.character("n"), scope: .palette))
        XCTAssertNil(route(.escape, scope: .palette))
        XCTAssertNil(route(.character("j"), scope: .palette))
        XCTAssertEqual(route(.character("k"), .command, scope: .palette), .palette)
    }

    func testNAsksAQuestionOnlyWhenNothingIsBeingTyped() {
        XCTAssertEqual(route(.character("n")), .newQuestion)
        XCTAssertNil(route(.character("n"), typing: true))
        XCTAssertEqual(route(.character("n"), .command, typing: true), .newQuestion)
    }

    func testCommandDigitsJumpToTheNthQuestion() {
        XCTAssertEqual(route(.character("1"), .command), .jumpToQuestion(1))
        XCTAssertEqual(route(.character("9"), .command), .jumpToQuestion(9))
        XCTAssertNil(route(.character("0"), .command))
        XCTAssertNil(route(.character("3")))
    }

    func testOptionArrowsWalkTheList() {
        XCTAssertEqual(route(.up, .option, scope: .question(railOpen: false)), .previousQuestion)
        XCTAssertEqual(route(.down, .option, scope: .question(railOpen: false)), .nextQuestion)
    }

    func testCommandBackslashTogglesTheSidebar() {
        XCTAssertEqual(route(.character("\\"), .command), .toggleSidebar)
    }

    func testJAndKWalkTheClaimsOfAQuestion() {
        let scope = KeyScope.question(railOpen: false)
        XCTAssertEqual(route(.character("j"), scope: scope), .nextClaim)
        XCTAssertEqual(route(.character("k"), scope: scope), .previousClaim)
        XCTAssertNil(route(.character("j"), scope: scope, typing: true))
        XCTAssertNil(route(.character("j"), scope: .list))
    }

    func testReturnOpensTheFocusedClaimsSourceAndBracketsCycleThem() {
        let scope = KeyScope.question(railOpen: true)
        XCTAssertEqual(route(.returnKey, scope: scope), .openSource)
        XCTAssertEqual(route(.character("]"), scope: scope), .nextSource)
        XCTAssertEqual(route(.character("["), scope: scope), .previousSource)
        XCTAssertNil(route(.returnKey, scope: scope, typing: true))
    }

    func testEscapeClosesTheRailAndOtherwiseDoesNothing() {
        XCTAssertEqual(route(.escape, scope: .question(railOpen: true)), .closeRail)
        XCTAssertNil(route(.escape, scope: .question(railOpen: false)))
    }

    func testCommandReturnOpensTheOriginalOfTheOpenSource() {
        XCTAssertEqual(route(.returnKey, .command, scope: .question(railOpen: true)), .openOriginal)
        XCTAssertNil(route(.returnKey, .command, scope: .question(railOpen: false)))
    }

    func testQuestionVerbsAreSingleLettersExceptWhenTyping() {
        let scope = KeyScope.question(railOpen: false)
        XCTAssertEqual(route(.character("g"), scope: scope), .toggleWork)
        XCTAssertEqual(route(.character("r"), scope: scope), .researchConflict)
        XCTAssertEqual(route(.character("e"), scope: scope), .toggleEarlier)
        XCTAssertNil(route(.character("g"), scope: scope, typing: true))
    }

    func testCommandLFocusesTheFollowUpComposer() {
        XCTAssertEqual(route(.character("l"), .command, scope: .question(railOpen: false)), .followUp)
        XCTAssertEqual(route(.character("l"), .command, scope: .question(railOpen: false), typing: true), .followUp)
    }

    func testCommandShiftCCopiesTheAnswerAndPlainCommandCDoesNot() {
        let scope = KeyScope.question(railOpen: false)
        XCTAssertEqual(route(.character("c"), [.command, .shift], scope: scope), .copyMarkdown)
        XCTAssertNil(route(.character("c"), .command, scope: scope))
        XCTAssertNil(route(.character("c"), [.command, .shift], scope: .list))
    }

    func testCommandPeriodStopsTheRunningQuestion() {
        XCTAssertEqual(route(.character("."), .command, scope: .question(railOpen: false)), .stop)
    }

    func testTabFlipsQuickAndDeepInTheComposerAndOnTheConfirmCard() {
        XCTAssertEqual(route(.tab, scope: .composer, typing: true), .toggleTier)
        XCTAssertEqual(route(.tab, scope: .scoping(.confirming)), .toggleTier)
        XCTAssertNil(route(.tab, scope: .list))
        XCTAssertNil(route(.tab, scope: .scoping(.clarifying)))
    }

    func testClarifyingKeysPickOptionsByRow() {
        let scope = KeyScope.scoping(.clarifying)
        XCTAssertEqual(route(.character("1"), scope: scope), .pickOption(question: 0, option: 0))
        XCTAssertEqual(route(.character("4"), scope: scope), .pickOption(question: 0, option: 3))
        XCTAssertEqual(route(.character("w"), scope: scope), .pickOption(question: 1, option: 1))
        XCTAssertEqual(route(.character("D"), scope: scope), .pickOption(question: 2, option: 2))
        XCTAssertNil(route(.character("1"), scope: scope, typing: true))
        XCTAssertEqual(route(.character("1"), .command, scope: scope), .jumpToQuestion(1))
    }

    func testClarifyingReturnContinuesAndEscapeGoesBackToYourWords() {
        let scope = KeyScope.scoping(.clarifying)
        XCTAssertEqual(route(.returnKey, scope: scope), .continueScoping)
        XCTAssertEqual(route(.escape, scope: scope), .backToWords)
        XCTAssertNil(route(.returnKey, scope: scope, typing: true))
    }

    func testTheConfirmCardStartsOnReturnEditsOnEAndGoesBackOnEscape() {
        let scope = KeyScope.scoping(.confirming)
        XCTAssertEqual(route(.returnKey, scope: scope), .startRun)
        XCTAssertEqual(route(.returnKey, .command, scope: scope, typing: true), .startRun)
        XCTAssertEqual(route(.character("e"), scope: scope), .editResolved)
        XCTAssertEqual(route(.escape, scope: scope), .backToWords)
        XCTAssertNil(route(.character("e"), scope: scope, typing: true))
    }

    func testWhileTheQuestionIsBeingRead_EscapeGoesBackToYourWords() {
        XCTAssertEqual(route(.escape, scope: .scoping(.scoping)), .backToWords)
    }

    func testTheComposerAsksOnReturnAndNewlinesOnShiftReturn() {
        XCTAssertEqual(route(.returnKey, scope: .composer, typing: true), .ask)
        XCTAssertEqual(route(.returnKey, .command, scope: .composer, typing: true), .ask)
        XCTAssertNil(route(.returnKey, .shift, scope: .composer, typing: true))
    }

    func testTheScopeFollowsWhatIsOnScreen() {
        XCTAssertEqual(KeyScope.resolve(paletteOpen: true, onNewQuestion: true, step: .drafting, railOpen: true), .palette)
        XCTAssertEqual(KeyScope.resolve(paletteOpen: false, onNewQuestion: true, step: .drafting, railOpen: false), .composer)
        XCTAssertEqual(KeyScope.resolve(paletteOpen: false, onNewQuestion: true, step: .clarifying, railOpen: false), .scoping(.clarifying))
        XCTAssertEqual(KeyScope.resolve(paletteOpen: false, onNewQuestion: false, step: .confirming, railOpen: false), .question(railOpen: false))
        XCTAssertEqual(KeyScope.resolve(paletteOpen: false, onNewQuestion: false, step: .drafting, railOpen: true), .question(railOpen: true))
    }
}
