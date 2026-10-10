import XCTest
@testable import QuorumCore

final class ScopingTests: XCTestCase {

    private func brief(asked: String = "blockchain", resolved: String = "Jak działa blockchain?", title: String = "Blockchain: jak działa",
                       language: String = "pl", tier: Tier = .quick, reason: String = "Pytanie ogólne.",
                       clarifications: [Clarification] = []) -> Brief {
        Brief(asked: asked, question: resolved, title: title, language: language, tier: tier, suggestedTier: tier,
              tierReason: reason, clarifications: clarifications)
    }

    private let aspect = ScopeQuestion(id: "aspect", text: "Który aspekt Cię interesuje?", multi: false, options: [
        ScopeOption(id: "1", label: "Technologia"), ScopeOption(id: "2", label: "Biznes"), ScopeOption(id: "3", label: "Prawo")])
    private let focus = ScopeQuestion(id: "focus", text: "Na kim się skupić?", multi: true, options: [
        ScopeOption(id: "1", label: "DoorDash"), ScopeOption(id: "2", label: "Wolt")])

    private func clear(_ b: Brief) -> ScopeReply { ScopeReply(needsScoping: false, brief: b, questions: [], fallbackReason: nil) }
    private func vague(_ b: Brief) -> ScopeReply { ScopeReply(needsScoping: true, brief: b, questions: [aspect, focus], fallbackReason: nil) }

    func testTheCommandIsJustScope() {
        XCTAssertEqual(EngineCommand.scope(), ["scope"])
    }

    func testAClearReplyDecodesIntoABriefWithItsTierAndReason() {
        let stdout = #"{"needs_scoping":false,"brief":{"asked":"is bun faster","question":"Is Bun faster than Node?","title":"Bun vs Node","language":"en","tier":"deep","suggested_tier":"deep","tier_reason":"Several benchmarks to reconcile.","clarifications":[]}}"# + "\n"

        guard case let .success(reply) = EngineReply.scope(stdout) else { return XCTFail("expected a scope reply") }

        XCTAssertFalse(reply.needsScoping)
        XCTAssertEqual(reply.brief, Brief(asked: "is bun faster", question: "Is Bun faster than Node?", title: "Bun vs Node", language: "en",
                                          tier: .deep, suggestedTier: .deep, tierReason: "Several benchmarks to reconcile.", clarifications: []))
        XCTAssertEqual(reply.questions, [])
        XCTAssertNil(reply.fallbackReason)
    }

    func testAVagueReplyCarriesItsQuestionsWithNumberedOptions() {
        let stdout = #"{"needs_scoping":true,"brief":{"asked":"blockchain","question":"Jak działa blockchain?","title":"Blockchain","language":"pl","tier":"quick","suggested_tier":"quick","tier_reason":"","clarifications":[]},"questions":[{"id":"aspect","text":"Który aspekt?","multi":false,"options":[{"id":"1","label":"Technologia"},{"id":"2","label":"Biznes"}]}]}"#

        guard case let .success(reply) = EngineReply.scope(stdout) else { return XCTFail("expected a scope reply") }

        XCTAssertTrue(reply.needsScoping)
        XCTAssertEqual(reply.questions, [ScopeQuestion(id: "aspect", text: "Który aspekt?", multi: false,
                                                       options: [ScopeOption(id: "1", label: "Technologia"), ScopeOption(id: "2", label: "Biznes")])])
    }

    func testAFallbackSaysWhy() {
        let stdout = #"{"needs_scoping":false,"fallback_reason":"the claude CLI is signed out","brief":{"asked":"x","question":"x","title":"x","language":"und","tier":"quick","suggested_tier":"quick","tier_reason":"","clarifications":[]}}"#

        guard case let .success(reply) = EngineReply.scope(stdout) else { return XCTFail("expected a scope reply") }

        XCTAssertEqual(reply.fallbackReason, "the claude CLI is signed out")
    }

    func testSilenceAndGarbageAreFailures() {
        XCTAssertEqual(EngineReply.scope(""), .failure(EngineFailure(reason: "quorum-engine said nothing when asked to scope the question")))
        XCTAssertEqual(EngineReply.scope("not json"), .failure(EngineFailure(reason: "quorum-engine answered the scoping request with something this app does not read")))
    }

    func testTheRequestSendsTheQuestionAndWhatWasAnswered() throws {
        let request = ScopeRequest(question: "blockchain", clarifications: [Clarification(question: "Który aspekt?", answer: "Technologia")])

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]

        XCTAssertEqual(json?["question"] as? String, "blockchain")
        XCTAssertEqual((json?["clarifications"] as? [[String: String]]), [["question": "Który aspekt?", "answer": "Technologia"]])
    }

    func testABriefIsSentToTheEngineInItsOwnSnakeCaseKeys() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(brief(tier: .deep))) as? [String: Any]

        XCTAssertEqual(json?["suggested_tier"] as? String, "deep")
        XCTAssertEqual(json?["tier_reason"] as? String, "Pytanie ogólne.")
        XCTAssertEqual(json?["tier"] as? String, "deep")
    }

    // MARK: The flow

    func testNothingStartsWithoutAQuestion() {
        var flow = ScopingFlow()
        flow.draft = "   \n"

        XCTAssertNil(flow.submit())
        XCTAssertEqual(flow.step, .drafting)
    }

    func testSubmittingAsksTheEngineToScopeTheTrimmedQuestion() {
        var flow = ScopingFlow()
        flow.draft = "  blockchain \n"

        XCTAssertEqual(flow.submit(), ScopeRequest(question: "blockchain", clarifications: []))
        XCTAssertEqual(flow.step, .scoping)
    }

    func testAClearQuestionGoesStraightToTheConfirmCard() {
        var flow = ScopingFlow()
        flow.draft = "Is Bun faster than Node?"
        _ = flow.submit()

        flow.receive(clear(brief(asked: "Is Bun faster than Node?", resolved: "Is Bun faster than Node?", language: "en")))

        XCTAssertEqual(flow.step, .confirming)
        XCTAssertEqual(flow.resolvedQuestion, "Is Bun faster than Node?")
    }

    func testAVagueQuestionAsksItsQuestionsFirst() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()

        flow.receive(vague(brief()))

        XCTAssertEqual(flow.step, .clarifying)
        XCTAssertEqual(flow.questions, [aspect, focus])
        XCTAssertEqual(flow.resolvedQuestion, "Jak działa blockchain?")
    }

    func testASingleChoiceReplacesItsPreviousPickAndAMultiChoiceToggles() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(vague(brief()))

        flow.pick(question: 0, option: 0)
        flow.pick(question: 0, option: 2)
        flow.pick(question: 1, option: 0)
        flow.pick(question: 1, option: 1)
        flow.pick(question: 1, option: 0)

        XCTAssertEqual(flow.picked(question: 0), ["3"])
        XCTAssertEqual(flow.picked(question: 1), ["2"])
    }

    func testContinuingSendsTheAnswersAsLabelsAndFreeText() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(vague(brief()))
        flow.pick(question: 0, option: 0)
        flow.pick(question: 1, option: 0)
        flow.pick(question: 1, option: 1)
        flow.ownWords = "bez kryptowalut"

        let request = flow.continueClarifying()

        XCTAssertEqual(request, ScopeRequest(question: "blockchain", clarifications: [
            Clarification(question: "Który aspekt Cię interesuje?", answer: "Technologia"),
            Clarification(question: "Na kim się skupić?", answer: "DoorDash, Wolt"),
            Clarification(question: "In your own words", answer: "bez kryptowalut"),
        ]))
        XCTAssertEqual(flow.step, .scoping)
    }

    func testContinuingWithNothingAnsweredAcceptsTheProposalAsItStands() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(vague(brief()))

        XCTAssertNil(flow.continueClarifying())
        XCTAssertEqual(flow.step, .confirming)
        XCTAssertEqual(flow.resolvedQuestion, "Jak działa blockchain?")
    }

    func testThereIsNeverASecondRoundOfQuestions() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(vague(brief()))
        flow.pick(question: 0, option: 0)
        _ = flow.continueClarifying()

        flow.receive(vague(brief(resolved: "Jak technicznie działa blockchain?")))

        XCTAssertEqual(flow.step, .confirming)
        XCTAssertEqual(flow.resolvedQuestion, "Jak technicznie działa blockchain?")
    }

    func testTheScopersRecommendationPicksTheTierUnlessTheUserChoseOne() {
        var flow = ScopingFlow()
        flow.draft = "Compare the EU, US and UK on foundation models"
        _ = flow.submit()
        flow.receive(clear(brief(asked: "x", resolved: "Compare …", language: "en", tier: .deep, reason: "Three regimes to reconcile.")))

        XCTAssertEqual(flow.tier, .deep)
        XCTAssertEqual(flow.tierReason, "Three regimes to reconcile.")

        var chosen = ScopingFlow()
        chosen.draft = "Is Bun faster than Node?"
        chosen.toggleTier()
        _ = chosen.submit()
        chosen.receive(clear(brief(asked: "x", resolved: "Is Bun faster than Node?", language: "en", tier: .quick)))

        XCTAssertEqual(chosen.tier, .deep)
    }

    func testTheTierIsQuickUntilAnyoneSaysOtherwise() {
        XCTAssertEqual(ScopingFlow().tier, .quick)
    }

    func testStartingSendsTheBriefWithTheChosenTier() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(clear(brief(tier: .quick)))
        flow.toggleTier()

        let start = flow.confirm()

        XCTAssertEqual(start?.brief?.tier, .deep)
        XCTAssertEqual(start?.brief?.suggestedTier, .quick)
        XCTAssertEqual(start?.question, "Jak działa blockchain?")
        XCTAssertEqual(start?.tier, .deep)
    }

    func testAnEditedResolvedQuestionIsWhatRuns() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(clear(brief()))

        flow.editResolved("Jak działa blockchain w logistyce?")

        XCTAssertEqual(flow.confirm()?.brief?.question, "Jak działa blockchain w logistyce?")
        XCTAssertEqual(flow.confirm()?.question, "Jak działa blockchain w logistyce?")
    }

    func testNothingStartsBeforeTheResolvedQuestionIsConfirmable() {
        var flow = ScopingFlow()
        XCTAssertNil(flow.confirm())
        flow.draft = "blockchain"
        _ = flow.submit()
        XCTAssertNil(flow.confirm())
        flow.receive(vague(brief()))
        XCTAssertNil(flow.confirm())
    }

    func testEscapeGoesBackToTheUsersOwnWordsToEditThem() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(clear(brief()))

        flow.edit()

        XCTAssertEqual(flow.step, .drafting)
        XCTAssertEqual(flow.draft, "blockchain")
        XCTAssertNil(flow.confirm())
    }

    func testResearchingTheOriginalWordingSendsNoBrief() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(vague(brief()))
        flow.toggleTier()

        let start = flow.runAsWritten()

        XCTAssertEqual(start, RunStart(question: "blockchain", brief: nil, tier: .deep))
    }

    func testAnEngineThatCannotScopeLeavesTheUsersWordsToConfirm() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()

        flow.fail(EngineFailure(reason: "quorum-engine could not be launched"))

        XCTAssertEqual(flow.step, .confirming)
        XCTAssertEqual(flow.resolvedQuestion, "blockchain")
        XCTAssertEqual(flow.fallbackReason, "quorum-engine could not be launched")
        XCTAssertNil(flow.confirm()?.brief)
        XCTAssertEqual(flow.confirm()?.question, "blockchain")
    }

    func testTheScopersOwnFallbackIsSaidOutLoudToo() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()

        flow.receive(ScopeReply(needsScoping: false, brief: brief(), questions: [], fallbackReason: "timed out"))

        XCTAssertEqual(flow.fallbackReason, "timed out")
    }

    func testTheFlowStartsOverOnceARunHasStarted() {
        var flow = ScopingFlow()
        flow.draft = "blockchain"
        _ = flow.submit()
        flow.receive(clear(brief()))
        flow.toggleTier()

        flow.reset()

        XCTAssertEqual(flow, ScopingFlow())
    }

    // MARK: Keys

    func testEachQuestionHasItsOwnRowOfKeys() {
        XCTAssertEqual(ScopeKeys.target(for: "1", questions: 3), ScopeKeys.Target(question: 0, option: 0))
        XCTAssertEqual(ScopeKeys.target(for: "4", questions: 3), ScopeKeys.Target(question: 0, option: 3))
        XCTAssertEqual(ScopeKeys.target(for: "q", questions: 3), ScopeKeys.Target(question: 1, option: 0))
        XCTAssertEqual(ScopeKeys.target(for: "R", questions: 3), ScopeKeys.Target(question: 1, option: 3))
        XCTAssertEqual(ScopeKeys.target(for: "d", questions: 3), ScopeKeys.Target(question: 2, option: 2))
    }

    func testKeysForAQuestionThatIsNotThereDoNothing() {
        XCTAssertNil(ScopeKeys.target(for: "q", questions: 1))
        XCTAssertNil(ScopeKeys.target(for: "x", questions: 3))
    }

    func testTheKeyLabelsAreTheOnesThatPickThem() {
        XCTAssertEqual(ScopeKeys.label(question: 0, option: 1), "2")
        XCTAssertEqual(ScopeKeys.label(question: 1, option: 2), "E")
        XCTAssertEqual(ScopeKeys.label(question: 2, option: 0), "A")
    }
}
