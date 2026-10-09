import XCTest
@testable import QuorumCore

/// The research graph: one authoritative structure the run grows, rebuilt here from a finished report.
/// Pure model — no layout, no UI, no spend. The fan is a special case, so every legacy run still resolves
/// to a graph.
final class ResearchGraphTests: XCTestCase {

    private func angle(_ id: String, _ question: String, round: Int = 1,
                       status: TopicStatus = .complete, headline: String = "",
                       findings: [Finding] = [], sources: [String] = [],
                       evidence: EvidenceIndex? = nil) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: question, status: status, preset: .standard,
            headline: headline.isEmpty ? "\(id) headline" : headline, confidenceSummary: "",
            sourcesConsulted: sources.count, costUSD: 1, durationSeconds: 10, note: nil,
            notePath: nil, transcriptPath: nil, round: round, sources: sources,
            findings: findings, evidence: evidence)
    }

    private func synthesis(_ id: String, _ question: String, round: Int = 1,
                           conflicts: [Conflict] = [], gaps: [String] = [],
                           findings: [Finding] = []) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: question, status: .complete, preset: .standard,
            headline: "synthesis headline", confidenceSummary: "", sourcesConsulted: 0,
            costUSD: 2, durationSeconds: 20, note: nil, notePath: nil, transcriptPath: nil,
            isSynthesis: true, conflicts: conflicts, gaps: gaps, round: round, findings: findings)
    }

    private func reconciliation(_ id: String, _ question: String) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: question, status: .complete, preset: .standard,
            headline: "the current answer", confidenceSummary: "", sourcesConsulted: 0,
            costUSD: 2, durationSeconds: 20, note: nil, notePath: nil, noteAction: .reconciled,
            transcriptPath: nil, isSynthesis: true, round: nil)
    }

    private func report(_ entries: [RunReport.TopicEntry]) -> RunReport {
        RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                  entries: entries, totalCostUSD: 5, runSpendCapUSD: 40)
    }

    private func document(_ sourceID: String, _ url: String) -> SourceDocument {
        SourceDocument(sourceID: sourceID, url: url, title: url, contentType: .html,
                       fetchedAt: nil, snapshotPath: "sources/\(sourceID).md", originalPath: nil,
                       textLength: 100, byteSize: 100, pageOffsets: [])
    }

    private func citation(_ id: String, _ sourceID: String) -> Citation {
        Citation(id: id, sourceID: sourceID, quote: "quote", start: 0, end: 5, match: .exact, page: nil)
    }

    // MARK: the fan as a special case

    func testLegacyReportRebuildsAsRootQuestionAnglesAndSynthesis() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            angle("a2", "angle two"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.node("root")?.kind, .question)
        XCTAssertEqual(graph.node("root")?.title, "the root question")
        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1", "a2"])
        XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["s"])
    }

    func testAnglesDecomposeFromTheRootAndFeedTheSynthesis() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            angle("a2", "angle two"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to).sorted(), ["a1", "a2"])
        XCTAssertTrue(graph.edges(of: .decomposes).allSatisfy { $0.from == "root" })
        XCTAssertEqual(graph.edges(of: .synthesizes).map(\.from).sorted(), ["a1", "a2"])
        XCTAssertTrue(graph.edges(of: .synthesizes).allSatisfy { $0.to == "s" })
    }

    func testAnInquiryIsPlacedOneLevelBelowTheRoot() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.node("root")?.depth, 0)
        XCTAssertEqual(graph.node("a1")?.depth, 1)
    }

    /// A later round's angles chase the prior synthesis's open points, so they hang off that synthesis
    /// rather than off the root — the diagram shows the dive deepening instead of one flat fan.
    func testLaterRoundAnglesResolveThePriorRoundsSynthesis() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase the conflict", round: 2),
            synthesis("s2", "the root question", round: 2),
        ]))

        XCTAssertEqual(graph.edges(of: .resolves).map { "\($0.from)→\($0.to)" }, ["s1→a2"])
        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to), ["a1"])
        XCTAssertEqual(graph.node("a2")?.round, 2)
    }

    /// An angle feeds the answer of its own round and no other. Wiring every angle into every later draft
    /// hangs a full-height wire down the canvas per angle per round, and all that ladder says is that the
    /// run had rounds — which the chain from one draft to the next already says, in one line.
    func testAnAngleFeedsTheAnswerOfItsOwnRoundOnly() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase the conflict", round: 2),
            synthesis("s2", "the root question", round: 2),
        ]))

        XCTAssertEqual(graph.edges(of: .synthesizes).map { "\($0.from)→\($0.to)" }.sorted(),
                       ["a1→s1", "a2→s2"])
    }

    func testTheFusedAnswerHangsOffTheDraftItSupersedesRatherThanEveryAngle() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase it", round: 2),
            synthesis("s2", "the root question", round: 2),
            reconciliation("s3", "the root question"),
        ]))

        XCTAssertEqual(graph.edges(of: .synthesizes).filter { $0.to == "s3" }.map(\.from), ["s2"])
    }

    func testSkippedEntriesAreLeftOutEntirely() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            angle("a2", "never ran", status: .skipped),
            synthesis("s", "the root question"),
        ]))

        XCTAssertNil(graph.node("a2"))
        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1"])
    }

    func testAReportWithNoSynthesisStillResolvesToAGraph() {
        let graph = ResearchGraph.from(report: report([angle("a1", "a lone topic")]))

        XCTAssertEqual(graph.node("root")?.title, "a lone topic")
        XCTAssertEqual(graph.nodes(of: .synthesis), [])
        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to), ["a1"])
    }

    // MARK: evidence becomes structure

    func testCapturedDocumentsBecomeSourceNodes() {
        let evidence = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                     citations: [citation("a1c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: evidence),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.nodes(of: .source).map(\.id), ["s3"])
        XCTAssertEqual(graph.node("s3")?.title, "https://example.com/a")
    }

    func testTheSameDocumentReachedByTwoAnglesIsOneNode() {
        let first = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                  citations: [citation("a1c1", "s3")])
        let second = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                   citations: [citation("a2c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: first),
            angle("a2", "angle two", evidence: second),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.nodes(of: .source).map(\.id), ["s3"])
    }

    /// The cross-angle agreement the fan-out exists to produce: two blind angles reaching one document
    /// independently — drawn as an edge on the one diagram of the run, rather than a tie on a second one.
    func testADocumentTwoAnglesReachedIndependentlyGetsCorroboratesEdges() {
        let first = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                  citations: [citation("a1c1", "s3")])
        let second = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                   citations: [citation("a2c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: first),
            angle("a2", "angle two", evidence: second),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.edges(of: .corroborates).map(\.to).sorted(), ["a1", "a2"])
        XCTAssertTrue(graph.edges(of: .corroborates).allSatisfy { $0.from == "s3" })
    }

    func testADocumentOnlyOneAngleReachedIsNotCorroboration() {
        let evidence = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                     citations: [citation("a1c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: evidence),
            angle("a2", "angle two"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.edges(of: .corroborates), [])
    }

    // MARK: claims become structure

    func testFindingsBecomeNodesUnderTheirInquiry() {
        let finding = Finding(claim: "prices rose 12%", sources: ["https://example.com/a"],
                              confidence: .high, citationIDs: ["a1c1"])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", findings: [finding]),
            synthesis("s", "the root question"),
        ]))

        let findings = graph.nodes(of: .finding)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.title, "prices rose 12%")
        XCTAssertEqual(graph.edges(of: .reports).map(\.from), ["a1"])
    }

    func testAFindingCitesTheSourceItsCitationResolvesTo() {
        let finding = Finding(claim: "prices rose 12%", sources: ["https://example.com/a"],
                              confidence: .high, citationIDs: ["a1c1"])
        let evidence = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                     citations: [citation("a1c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", findings: [finding], evidence: evidence),
            synthesis("s", "the root question"),
        ]))

        // Both the angle that reached the document and the claim that quotes it point at the same node.
        XCTAssertEqual(Set(graph.edges(of: .cites).map(\.from)), ["a1", "a1·finding·0"])
        XCTAssertTrue(graph.edges(of: .cites).allSatisfy { $0.to == "s3" })
    }

    func testSynthesisConflictsAndGapsBecomeTheirOwnNodes() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            synthesis("s", "the root question",
                      conflicts: [Conflict(claim: "they disagree on scale", positions: ["a: big", "b: small"])],
                      gaps: ["nobody measured retention"]),
        ]))

        XCTAssertEqual(graph.nodes(of: .conflict).map(\.title), ["they disagree on scale"])
        XCTAssertEqual(graph.nodes(of: .gap).map(\.title), ["nobody measured retention"])
        XCTAssertTrue(graph.edges(of: .surfaces).allSatisfy { $0.from == "s" })
    }

    // MARK: shape metrics — what the layout picks from

    func testMetricsDescribeTheShapeTheLayoutWillDrawFrom() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            angle("a2", "angle two"),
            angle("a3", "angle three"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.maxDepth, 2)
        XCTAssertEqual(graph.widestRank, 3)
    }

    func testConvergenceIsTheShareOfSourcesMoreThanOneInquiryReached() {
        let shared = document("s3", "https://example.com/a")
        let first = EvidenceIndex(documents: [shared, document("s4", "https://example.com/b")],
                                  citations: [citation("a1c1", "s3"), citation("a1c2", "s4")])
        let second = EvidenceIndex(documents: [shared], citations: [citation("a2c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: first),
            angle("a2", "angle two", evidence: second),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.sourceConvergence, 0.5, accuracy: 0.0001)
    }

    // MARK: the skeleton — what a reader sees before asking for detail

    private func busyReport() -> RunReport {
        let findings = (1...10).map { Finding(claim: "claim \($0)", sources: [], confidence: .high) }
        return report([
            angle("a1", "angle one", findings: findings),
            angle("a2", "angle two", findings: findings),
            synthesis("s", "the root question",
                      conflicts: [Conflict(claim: "they disagree", positions: ["x", "y"])],
                      gaps: ["nobody measured retention"]),
        ])
    }

    /// A real run puts 20-plus findings on one rank, which is a 5000-point-wide row nobody can read. The
    /// structure is what the canvas shows first; the claims are what you ask a node for.
    func testTheSkeletonHidesClaimsAndSourcesUntilTheyAreAskedFor() {
        let graph = ResearchGraph.from(report: busyReport()).skeleton(expanding: [])

        XCTAssertEqual(graph.nodes(of: .finding), [])
        XCTAssertEqual(graph.nodes(of: .conflict), [])
        XCTAssertEqual(graph.nodes(of: .gap), [])
        XCTAssertEqual(graph.nodes(of: .inquiry).count, 2)
        XCTAssertNotNil(graph.node("root"))
        XCTAssertNotNil(graph.node("s"))
    }

    func testExpandingOneNodeRevealsOnlyItsOwnDetail() {
        let graph = ResearchGraph.from(report: busyReport()).skeleton(expanding: ["a1"])

        XCTAssertEqual(graph.nodes(of: .finding).count, 10)
        XCTAssertTrue(graph.edges(of: .reports).allSatisfy { $0.from == "a1" })
    }

    func testTheSkeletonStaysNarrowEnoughToRead() {
        let full = ResearchGraph.from(report: busyReport())
        let skeleton = full.skeleton(expanding: [])

        XCTAssertGreaterThan(full.widestRank, 10)
        XCTAssertLessThanOrEqual(skeleton.widestRank, 3)
    }

    func testACardKnowsHowMuchDetailItIsHiding() {
        let graph = ResearchGraph.from(report: busyReport())

        XCTAssertEqual(graph.detailCount(under: "a1"), 10)
        XCTAssertEqual(graph.detailCount(under: "s"), 2)
        XCTAssertEqual(graph.detailCount(under: "root"), 0)
    }

    func testAnExpandedSourceStaysOneNodeEvenWhenTwoAnglesReachedIt() {
        let shared = document("s3", "https://example.com/a")
        let first = EvidenceIndex(documents: [shared], citations: [citation("a1c1", "s3")])
        let second = EvidenceIndex(documents: [shared], citations: [citation("a2c1", "s3")])
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", evidence: first),
            angle("a2", "angle two", evidence: second),
            synthesis("s", "the root question"),
        ])).skeleton(expanding: ["a1"])

        XCTAssertEqual(graph.nodes(of: .source).map(\.id), ["s3"])
    }

    // MARK: what the canvas needs to collapse and focus

    func testCollapsingANodeHidesWhatHangsBelowItButKeepsTheNode() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one",
                  findings: [Finding(claim: "a claim", sources: [], confidence: .high)]),
            angle("a2", "angle two"),
            synthesis("s", "the root question"),
        ]))

        let visible = graph.hiding(under: ["a1"])

        XCTAssertNotNil(visible.node("a1"))
        XCTAssertEqual(visible.nodes(of: .finding), [])
        XCTAssertNotNil(visible.node("a2"))
    }

    func testCollapsingKeepsAnEdgeOnlyWhenBothEndsSurvive() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one",
                  findings: [Finding(claim: "a claim", sources: [], confidence: .high)]),
            synthesis("s", "the root question"),
        ]))

        let visible = graph.hiding(under: ["a1"])

        XCTAssertEqual(visible.edges(of: .reports), [])
        XCTAssertEqual(visible.edges(of: .decomposes).map(\.to), ["a1"])
    }

    func testFocusLightsTheWholePathBackToTheRoot() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "the follow-up", round: 2),
        ]))

        XCTAssertEqual(graph.ancestry(of: "a2"), ["a2", "s1", "a1", "root"])
    }

    func testFocusOnAnUnknownNodeLightsNothing() {
        let graph = ResearchGraph.from(report: report([angle("a1", "angle one")]))

        XCTAssertEqual(graph.ancestry(of: "ghost"), [])
    }

    func testAncestryTerminatesEvenIfTheGraphSomehowLoops() {
        var graph = ResearchGraph()
        graph.insert(GraphNode(id: "a", kind: .inquiry, title: "a", state: .derived))
        graph.insert(GraphNode(id: "b", kind: .inquiry, title: "b", state: .derived))
        graph.connect(GraphEdge(from: "a", to: "b", kind: .spawned))
        graph.connect(GraphEdge(from: "b", to: "a", kind: .spawned))

        XCTAssertEqual(graph.ancestry(of: "a").sorted(), ["a", "b"])
    }

    func testConvergenceIsZeroWhenNothingWasCaptured() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.sourceConvergence, 0)
    }

    // MARK: the loop a finished run was judged by

    private func verdict(_ lens: String, round: Int = 1, status: String = "pass",
                         objections: [RunStreamParser.ObjectionEvent] = []) -> RunValidation.Verdict {
        RunValidation.Verdict(id: "v\(round)_\(lens)", lens: lens, title: "\(lens) critic",
                              round: round, status: status, objections: objections)
    }

    private func validated(_ entries: [RunReport.TopicEntry],
                           _ verdicts: [RunValidation.Verdict]) -> RunReport {
        RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                  entries: entries, totalCostUSD: 5, runSpendCapUSD: 40,
                  validation: RunValidation(status: "validated", holds: true, blocking: 0,
                                            spendUSD: Decimal(string: "0.08")!, rounds: 1,
                                            objectionsAdmitted: 0, objectionsResolved: 0,
                                            objectionsOutstanding: [], verdicts: verdicts))
    }

    func testAValidatedRunRebuildsTheVerdictsItsAnswerWasJudgedBy() {
        let objection = RunStreamParser.ObjectionEvent(
            lens: "coverage", statement: "no 2025 pricing", severity: "blocking",
            followup: "find the pricing page")
        let graph = ResearchGraph.from(report: validated(
            [angle("a1", "angle one"), synthesis("s", "the root question")],
            [verdict("claim_sweep"), verdict("coverage", status: "objections(1)", objections: [objection])]))

        XCTAssertEqual(graph.nodes(of: .verdict).map(\.id), ["v1_claim_sweep", "v1_coverage"])
        XCTAssertEqual(graph.node("v1_claim_sweep")?.state, .judged(objections: 0))
        XCTAssertEqual(graph.node("v1_coverage")?.state, .judged(objections: 1))
        XCTAssertEqual(graph.node("v1_coverage")?.lens, "coverage")
        XCTAssertEqual(graph.node("v1_coverage")?.objections, [objection])
    }

    /// A verdict points at the answer it read, exactly as the live fold draws it — never hangs under it.
    func testEachVerdictJudgesItsOwnRoundsAnswer() {
        let graph = ResearchGraph.from(report: validated([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase it", round: 2),
            synthesis("s2", "the root question", round: 2),
        ], [verdict("coverage", round: 1), verdict("coverage", round: 2)]))

        XCTAssertEqual(graph.edges(of: .judges).map { "\($0.from)→\($0.to)" },
                       ["v1_coverage→s1", "v2_coverage→s2"])
        XCTAssertFalse(graph.children(of: "s1").contains { $0.kind == .verdict })
    }

    func testAValidatorTaskTheRunSkippedIsNotRebuiltAsAPass() {
        let graph = ResearchGraph.from(report: validated(
            [angle("a1", "angle one"), synthesis("s", "the root question")],
            [verdict("claim_sweep", status: "skipped")]))

        XCTAssertEqual(graph.node("v1_claim_sweep")?.state, .derived)
    }

    func testALegacyReportRebuildsWithNoVerdictsAtAll() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"),
            synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.nodes(of: .verdict), [])
        XCTAssertEqual(graph.edges(of: .judges), [])
    }

    // MARK: the answer the dive currently holds

    func testTheReconciledAnswerIsTheTerminalSynthesisNode() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase it", round: 2),
            synthesis("s2", "the root question", round: 2),
            reconciliation("fused", "the root question"),
        ]))

        XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["s1", "s2", "fused"])
        XCTAssertEqual(graph.node("fused")?.isReconciled, true)
        XCTAssertEqual(graph.node("s2")?.isReconciled, false)
        XCTAssertGreaterThan(graph.node("fused")?.depth ?? 0, graph.node("s2")?.depth ?? 0)
        XCTAssertTrue(graph.edges(of: .synthesizes).contains { $0.from == "s2" && $0.to == "fused" })
    }

    func testTheReconciledAnswerHangsBelowEveryRoundThatFedIt() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase it", round: 2),
            synthesis("s2", "the root question", round: 2),
            reconciliation("fused", "the root question"),
        ]))

        XCTAssertEqual(graph.ancestry(of: "fused").sorted(), ["a1", "a2", "fused", "root", "s1", "s2"])
    }

    /// The node the canvas opens focused, with the rail already reading it: the first thing on screen is
    /// the answer the dive holds, beside the shape that produced it (PRD 09 R1).
    func testTheDiveOpensOnTheAnswerItCurrentlyHolds() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one", round: 1),
            synthesis("s1", "the root question", round: 1),
            angle("a2", "chase it", round: 2),
            synthesis("s2", "the root question", round: 2),
            reconciliation("fused", "the root question"),
        ]))

        XCTAssertEqual(graph.answer?.id, "fused")
    }

    func testASingleRoundRunOpensOnItsOnlySynthesis() {
        let graph = ResearchGraph.from(report: report([
            angle("a1", "angle one"), synthesis("s", "the root question"),
        ]))

        XCTAssertEqual(graph.answer?.id, "s")
    }

    /// A run still planning has drafted nothing, and a canvas cannot open on an answer that does not exist.
    func testARunWithNoAnswerYetOpensOnNothing() {
        var graph = ResearchGraph()
        graph.insert(GraphNode(id: "root", kind: .question, title: "q", state: .asked(.approved)))

        XCTAssertNil(graph.answer)
    }

    /// Whatever produced a run — a legacy fan, a graph run with evidence, a validated v4 dive — History
    /// opens the same component on the same structure. There is no second reading path to keep alive.
    func testEveryFinishedRunOpensAsAGraphWhateverProducedIt() {
        let evidence = EvidenceIndex(documents: [document("s3", "https://example.com/a")],
                                     citations: [citation("a1c1", "s3")])
        let reports = [
            report([angle("a1", "angle one"), synthesis("s", "the root question")]),
            report([angle("a1", "angle one", evidence: evidence), synthesis("s", "the root question")]),
            validated([angle("a1", "angle one"), synthesis("s", "the root question")],
                      [verdict("coverage")]),
        ]

        for report in reports {
            let graph = ResearchGraph.from(report: report)
            XCTAssertEqual(graph.node(ResearchGraph.rootID)?.kind, .question)
            XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1"])
            XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["s"])
        }
    }
}
