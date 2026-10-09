import XCTest
@testable import QuorumCore

/// One table every surface reads its icons, tints and badges out of. The graph, the sidebar badges and the
/// digest used to answer "what colour is complete?" three times over; the answer now lives here, where
/// it can be argued with in a test instead of in three view files.
final class NodeStyleTests: XCTestCase {

    private func node(_ kind: GraphNodeKind, state: GraphNodeState = .derived,
                      lens: String? = nil, objections: Int = 0) -> GraphNode {
        GraphNode(id: "n", kind: kind, title: "n", state: state, lens: lens)
    }

    // MARK: kinds

    func testEveryKindOfNodeIsDrawnAsSomethingAndNamedSomething() {
        for kind in GraphNodeKind.allCases {
            let style = NodeStyle.kind(kind)
            XCTAssertFalse(style.icon.isEmpty, "\(kind) has no icon")
            XCTAssertFalse(style.label.isEmpty, "\(kind) has no label")
        }
    }

    func testNoTwoKindsShareAnIcon() {
        let icons = GraphNodeKind.allCases.map { NodeStyle.kind($0).icon }
        XCTAssertEqual(Set(icons).count, icons.count, "two kinds drawn the same is two kinds nobody can tell apart")
    }

    func testAVerdictIsDrawnAsTheLensThatFiledItRatherThanAsAFourthGavel() {
        XCTAssertEqual(NodeStyle.node(node(.verdict, lens: "coverage")).icon, "checklist")
        XCTAssertEqual(NodeStyle.node(node(.verdict, lens: "sources")).icon, "doc.text.magnifyingglass")
        XCTAssertEqual(NodeStyle.node(node(.verdict, lens: "claim_sweep")).label, "claim sweep")
        XCTAssertEqual(NodeStyle.node(node(.verdict)).icon, NodeStyle.kind(.verdict).icon,
                       "a verdict with no lens still reads as a verdict")
    }

    /// A finished dive ends on one answer, and it is not "the fourth synthesis" — the node the reader lands
    /// on says which of the syntheses on the canvas the run currently holds.
    func testTheFusedAnswerIsDrawnAsTheAnswerTheDiveHoldsRatherThanAsAnotherSynthesis() {
        let fused = GraphNode(id: "fused", kind: .synthesis, title: "the current answer",
                              state: .worked(.complete), isReconciled: true)
        let round = node(.synthesis, state: .worked(.complete))

        XCTAssertEqual(NodeStyle.node(fused).label, "Current answer")
        XCTAssertNotEqual(NodeStyle.node(fused).icon, NodeStyle.node(round).icon)
        XCTAssertEqual(NodeStyle.node(fused).tint, NodeStyle.kind(.synthesis).tint)
    }

    func testAnAngleIsDrawnTheSameWhereverItIs() {
        XCTAssertEqual(NodeStyle.node(node(.inquiry)).icon, NodeStyle.kind(.inquiry).icon)
        XCTAssertEqual(NodeStyle.node(node(.inquiry)).tint, NodeStyle.kind(.inquiry).tint)
    }

    // MARK: what a node's state says on it

    func testAVerdictThatFiledNothingSealsAndOneThatFiledReadsAsAnObjection() {
        let held = NodeStyle.state(of: node(.verdict, state: .judged(objections: 0)))
        let filed = NodeStyle.state(of: node(.verdict, state: .judged(objections: 2)))

        XCTAssertEqual(held.tint, .green)
        XCTAssertEqual(held.badge, "HELD")
        XCTAssertEqual(filed.tint, .red)
        XCTAssertEqual(filed.badge, "2 OBJECTIONS")
    }

    func testAValidatorTaskTheRunSkippedIsNeverDrawnAsAPass() {
        let skipped = NodeStyle.state(of: node(.verdict, state: .derived))

        XCTAssertEqual(skipped.badge, "SKIPPED")
        XCTAssertNotEqual(skipped.tint, .green)
    }

    func testTheStatesTheRunIsMidwayThroughSpinRatherThanShowingAGlyph() {
        XCTAssertTrue(NodeStyle.state(of: node(.question, state: .asked(.planning))).showsProgress)
        XCTAssertTrue(NodeStyle.state(of: node(.inquiry, state: .worked(.running))).showsProgress)
        XCTAssertFalse(NodeStyle.state(of: node(.inquiry, state: .worked(.complete))).showsProgress)
    }

    func testAnOfferNobodyHasRuledOnYetSaysSoOnItsCard() {
        let pending = NodeStyle.state(of: node(.question, state: .asked(.pending)))

        XCTAssertEqual(pending.badge, "PENDING")
        XCTAssertEqual(pending.tint, .orange)
    }

    func testANodeDoingNothingInParticularBorrowsItsOwnKindsTint() {
        let quiet = NodeStyle.state(of: node(.source, state: .derived))

        XCTAssertNil(quiet.badge)
        XCTAssertEqual(quiet.tint, NodeStyle.kind(.source).tint)
        XCTAssertTrue(quiet.isMuted, "a node with nothing to report does not shout its outline")
    }

    // MARK: statuses, wherever they are drawn

    func testEveryTopicStatusResolvesToSomethingDrawable() {
        for status in TopicStatus.allCases {
            let style = NodeStyle.status(status)
            XCTAssertFalse(style.icon.isEmpty, "\(status) has no icon")
            XCTAssertEqual(style.label, status.label)
        }
    }

    func testTheOutcomesAPersonActsOnKeepTheirOwnColours() {
        XCTAssertEqual(NodeStyle.status(.complete).tint, .green)
        XCTAssertEqual(NodeStyle.status(.inconclusive).tint, .yellow)
        XCTAssertEqual(NodeStyle.status(.skipped).tint, .purple)
        for halted in [TopicStatus.haltedSpend, .haltedTime, .haltedManual, .error] {
            XCTAssertEqual(NodeStyle.status(halted).tint, .red, "\(halted) is a failure like any other")
        }
    }

    func testWorkInFlightSpinsRatherThanShowingAnIcon() {
        XCTAssertTrue(NodeStyle.status(.running).showsProgress)
        XCTAssertFalse(NodeStyle.status(.complete).showsProgress)
    }

    // MARK: the loop's own tints, defined once

    func testABlockingObjectionOutranksOneTheAnswerCanLiveWith() {
        XCTAssertEqual(NodeStyle.objection(severity: "blocking").tint, .red)
        XCTAssertEqual(NodeStyle.objection(severity: "minor").tint, .orange)
        XCTAssertNotEqual(NodeStyle.objection(severity: "blocking").icon,
                          NodeStyle.objection(severity: "minor").icon)
    }

    func testAJudgementIsWiredInTheColourItIsDrawnIn() {
        XCTAssertEqual(NodeStyle.edge(.judges), NodeStyle.kind(.verdict).tint)
        XCTAssertEqual(NodeStyle.edge(.cites), NodeStyle.kind(.source).tint)
        XCTAssertEqual(NodeStyle.edge(.decomposes), .neutral)
    }

    /// Reopening the question is the loop's one move, so the wire that does it is drawn in the colour of a
    /// question being raised rather than in the grey the run's own descent is drawn in.
    func testChasingAnOpenPointIsWiredLikeTheQuestionItIs() {
        XCTAssertEqual(NodeStyle.edge(.resolves), NodeStyle.edge(.spawned))
        XCTAssertNotEqual(NodeStyle.edge(.resolves), NodeStyle.edge(.decomposes))
    }

    func testAQuoteEitherCheckedOutAgainstItsSourceOrItDidNot() {
        XCTAssertEqual(NodeStyle.seal(verified: true).tint, .green)
        XCTAssertEqual(NodeStyle.seal(verified: true).icon, "checkmark.seal.fill")
        XCTAssertEqual(NodeStyle.seal(verified: false).tint, .orange)
    }

    // MARK: the chip ladder, drawn out of the same table

    func testEveryRungOfTheChipLadderIsDrawnAndNamed() {
        for tier in CitationTier.allCases {
            let style = NodeStyle.citation(tier)
            XCTAssertFalse(style.icon.isEmpty, "\(tier) has no icon")
            XCTAssertFalse(style.label.isEmpty, "\(tier) has no label")
        }
    }

    /// A located quote the sweep found does not carry its claim is the one rung that must never be mistaken
    /// for a pass — it is drawn against the answer, not with it.
    func testAQuoteThatDoesNotSupportItsClaimIsDrawnAgainstTheAnswer() {
        XCTAssertEqual(NodeStyle.citation(.unsupported).tint, .red)
        XCTAssertNotEqual(NodeStyle.citation(.unsupported).icon, NodeStyle.citation(.supported).icon)
        XCTAssertNotEqual(NodeStyle.citation(.unsupported).tint, NodeStyle.citation(.close).tint)
        XCTAssertFalse(NodeStyle.citation(.unsupported).isMuted, "a warning is not a quiet chip")
    }

    func testOnlyTheRungWithNothingBehindItIsDrawnHollow() {
        XCTAssertTrue(NodeStyle.citation(.unresolved).isMuted)
        for tier in [CitationTier.supported, .close, .unsupported] {
            XCTAssertFalse(NodeStyle.citation(tier).isMuted)
        }
    }
}
