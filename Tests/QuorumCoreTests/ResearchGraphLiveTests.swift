import XCTest
@testable import QuorumCore

/// Folding the run's live stream into the same graph History rebuilds from a report. A node appears while
/// the run is going, and a pending question is a first-class part of the picture rather than a dialog.
final class ResearchGraphLiveTests: XCTestCase {

    private func fold(_ lines: [String]) -> ResearchGraph {
        var graph = ResearchGraph()
        for line in lines {
            guard let event = RunStreamParser.parse(line) else { continue }
            graph.apply(event)
        }
        return graph
    }

    private let rootLine = """
    {"type":"graph_node","node":{"id":"root","kind":"question","title":"How should we price it?",\
    "parent_ids":[],"depth":0,"round":1,"status":"approved","origin":"root"}}
    """
    private let angleLine = """
    {"type":"graph_node","node":{"id":"a1","kind":"inquiry","title":"Competitor pricing",\
    "parent_ids":[],"depth":1,"round":1,"status":"queued","origin":"planner"}}
    """
    private let decomposesLine = """
    {"type":"graph_edge","edge":{"from":"root","to":"a1","kind":"decomposes"}}
    """
    private let pendingLine = """
    {"type":"graph_node","node":{"id":"q1","kind":"question","title":"What did the 2024 filing say?",\
    "parent_ids":["a1"],"depth":2,"round":1,"status":"pending","origin":"spawn",\
    "meta":{"why":"a1 hit a paywall","provoked_by":"s3f9a1c2","est_cost_usd":2.5}}}
    """

    // MARK: nodes and edges arriving live

    func testAGraphNodeLineBecomesANode() {
        let graph = fold([rootLine, angleLine])

        XCTAssertEqual(graph.node("root")?.kind, .question)
        XCTAssertEqual(graph.node("a1")?.title, "Competitor pricing")
        XCTAssertEqual(graph.node("a1")?.depth, 1)
        XCTAssertEqual(graph.node("a1")?.origin, .planner)
    }

    func testAGraphEdgeLineBecomesAnEdge() {
        let graph = fold([rootLine, angleLine, decomposesLine])

        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to), ["a1"])
    }

    func testAPendingQuestionCarriesItsWhyAndItsPrice() {
        let graph = fold([rootLine, angleLine, pendingLine])
        let pending = graph.node("q1")

        XCTAssertEqual(pending?.state, .asked(.pending))
        XCTAssertEqual(pending?.title, "What did the 2024 filing say?")
        XCTAssertEqual(pending?.reason, "a1 hit a paywall")
        XCTAssertEqual(pending?.estimatedCostUSD, 2.5)
        XCTAssertEqual(pending?.provokedBy, "s3f9a1c2")
    }

    func testAnUpdateMovesANodeWithoutReplacingIt() {
        let graph = fold([rootLine, angleLine,
                          #"{"type":"graph_node_update","id":"a1","status":"complete","meta":{"cost_usd":0.42}}"#])

        XCTAssertEqual(graph.node("a1")?.state, .worked(.complete))
        XCTAssertEqual(graph.node("a1")?.title, "Competitor pricing")
        XCTAssertEqual(graph.node("a1")?.costUSD, Decimal(0.42))
    }

    func testApprovingAPendingQuestionMovesItOutOfPending() {
        let graph = fold([rootLine, angleLine, pendingLine,
                          #"{"type":"graph_node_update","id":"q1","status":"approved"}"#])

        XCTAssertEqual(graph.node("q1")?.state, .asked(.approved))
    }

    func testAnExpiredQuestionIsNotTheSameAsARefusedOne() {
        let graph = fold([rootLine, angleLine, pendingLine,
                          #"{"type":"graph_node_update","id":"q1","status":"expired"}"#])

        XCTAssertEqual(graph.node("q1")?.state, .asked(.expired))
    }

    func testARefusedQuestionKeepsTheReasonItWasRefusedFor() {
        let refused = """
        {"type":"graph_node","node":{"id":"r1","kind":"question","title":"already asked",\
        "parent_ids":["a1"],"depth":0,"round":1,"status":"rejected","origin":"spawn",\
        "meta":{"rejected_reason":"duplicate of a question already being asked"}}}
        """
        let graph = fold([rootLine, angleLine, refused])

        XCTAssertEqual(graph.node("r1")?.state, .asked(.rejected))
        XCTAssertEqual(graph.node("r1")?.reason, "duplicate of a question already being asked")
    }

    // MARK: planning, before the engine has said anything

    func testAGraphExistsFromTheMomentTheQuestionIsAsked() {
        let graph = ResearchGraph.planning(question: "How to compose an ideal restaurant menu?")

        XCTAssertEqual(graph.node("root")?.kind, .question)
        XCTAssertEqual(graph.node("root")?.title, "How to compose an ideal restaurant menu?")
        XCTAssertEqual(graph.node("root")?.state, .asked(.planning))
        XCTAssertEqual(graph.nodes.count, 1)
    }

    func testThePlannersOwnNodeIsWhereItsDecompositionStreams() {
        let graph = ResearchGraph.planning(question: "How to compose an ideal restaurant menu?",
                                           angleCount: 4)

        XCTAssertEqual(graph.node("root")?.subtitle, "decomposing into 4 angles…")
    }

    func testTheEngineTakesTheRootOverOncePlanningEnds() {
        var graph = ResearchGraph.planning(question: "How to compose an ideal restaurant menu?")
        for line in [rootLine, angleLine, decomposesLine] {
            if let event = RunStreamParser.parse(line) { graph.apply(event) }
        }

        XCTAssertEqual(graph.node("root")?.state, .asked(.approved))
        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1"])
        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to), ["a1"])
    }

    /// The engine is authoritative about state, so a node arriving twice moves rather than being ignored —
    /// but its identity and place on the canvas are kept, or the reader loses what they were looking at.
    func testANodeArrivingTwiceMovesInsteadOfDuplicating() {
        var graph = fold([rootLine, angleLine])
        let running = """
        {"type":"graph_node","node":{"id":"a1","kind":"inquiry","title":"Competitor pricing",\
        "parent_ids":[],"depth":1,"round":1,"status":"running","origin":"planner"}}
        """
        if let event = RunStreamParser.parse(running) { graph.apply(event) }

        XCTAssertEqual(graph.nodes(of: .inquiry).count, 1)
        XCTAssertEqual(graph.node("a1")?.state, .worked(.running))
    }

    func testAPlanEventAloneStillDrawsTheAnglesForATranscriptWithNoGraphEvents() {
        var graph = ResearchGraph.planning(question: "How to compose an ideal restaurant menu?")
        let plan = """
        {"type":"plan","angles":[{"angle_id":"a1","title":"Cost structure","prompt":"p"},\
        {"angle_id":"a2","title":"Guest psychology","prompt":"p"}]}
        """
        if let event = RunStreamParser.parse(plan) { graph.apply(event) }

        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.title), ["Cost structure", "Guest psychology"])
        XCTAssertEqual(graph.edges(of: .decomposes).map(\.to), ["a1", "a2"])
        XCTAssertEqual(graph.node("root")?.state, .asked(.approved))
    }

    // MARK: what the stream already carried before this PRD

    func testACapturedDocumentBecomesASourceNodeTiedToTheAngleThatFetchedIt() {
        let document = """
        {"type":"document","angle_id":"a1","document":{"source_id":"s3","url":"https://example.com/a",\
        "title":"A page","content_type":"html","text_length":10,"byte_size":10,"page_offsets":[]}}
        """
        let graph = fold([rootLine, angleLine, document])

        XCTAssertEqual(graph.nodes(of: .source).map(\.id), ["s3"])
        XCTAssertEqual(graph.edges(of: .cites).map { "\($0.from)→\($0.to)" }, ["a1→s3"])
    }

    func testTwoAnglesReachingOneDocumentTieTogetherLive() {
        let second = """
        {"type":"graph_node","node":{"id":"a2","kind":"inquiry","title":"Second angle",\
        "parent_ids":[],"depth":1,"round":1,"status":"queued","origin":"planner"}}
        """
        func fetched(_ angle: String) -> String {
            """
            {"type":"document","angle_id":"\(angle)","document":{"source_id":"s3","url":"https://example.com/a",\
            "title":"A page","content_type":"html","text_length":10,"byte_size":10,"page_offsets":[]}}
            """
        }
        let graph = fold([rootLine, angleLine, second, fetched("a1"), fetched("a2")])

        XCTAssertEqual(graph.nodes(of: .source).count, 1)
        XCTAssertEqual(graph.edges(of: .corroborates).map(\.to).sorted(), ["a1", "a2"])
    }

    func testAnAngleStatusLineStillMovesItsNode() {
        let graph = fold([rootLine, angleLine,
                          #"{"type":"angle_status","angle_id":"a1","status":"running"}"#])

        XCTAssertEqual(graph.node("a1")?.state, .worked(.running))
    }

    // MARK: PRD 07 R1 — the canvas is one of the surfaces that must say "unvalidated"

    func testTheGraphCarriesTheRunsGroundingTierFromItsFirstLine() {
        let unvalidated = fold([#"{"type":"run_start","session_id":"q","protocol_version":3,"grounding":"none"}"#,
                                rootLine, angleLine])
        XCTAssertEqual(unvalidated.grounding, .none)
        XCTAssertFalse(unvalidated.isValidated, "the live canvas knows before the first angle reports")

        let captured = fold([#"{"type":"run_start","session_id":"q","protocol_version":3,"grounding":"captured"}"#,
                             rootLine])
        XCTAssertTrue(captured.isValidated)
        XCTAssertTrue(fold([rootLine]).isValidated, "a stream from before the tier existed reads as it always did")
    }

    func testARunResultCanStillDeclareTheTierForAStreamJoinedLate() {
        let graph = fold([rootLine,
                          #"{"type":"run_result","status":"complete","grounding":"none","total_cost_usd":1,"topics":[]}"#])
        XCTAssertEqual(graph.grounding, .none)
    }

    func testAnUnknownLineChangesNothing() {
        let graph = fold([rootLine, #"{"type":"something_new","payload":1}"#])

        XCTAssertEqual(graph.nodes.count, 1)
    }

    func testAnUpdateForANodeThatNeverArrivedIsIgnored() {
        let graph = fold([rootLine, #"{"type":"graph_node_update","id":"ghost","status":"complete"}"#])

        XCTAssertNil(graph.node("ghost"))
    }

    // MARK: the whole run, from the engine's own fixture

    // MARK: PRD 06 — the loop's shape is the graph

    func testAVerdictHangsOffTheAnswerItJudgedAndCarriesWhatItFiled() {
        let graph = fold([rootLine, angleLine,
            #"{"type":"graph_node","node":{"id":"synthesis","kind":"synthesis","title":"Synthesis","parent_ids":[],"depth":2,"round":1,"status":"running","origin":"derived"}}"#,
            #"{"type":"graph_node","node":{"id":"v1_coverage","kind":"verdict","title":"Coverage critic","parent_ids":[],"depth":3,"round":1,"status":"objections(1)","origin":"derived","meta":{"lens":"coverage","objections":[{"lens":"coverage","statement":"the answer never states 2025 pricing","severity":"blocking","followup":"find Acme's 2025 published pricing page"}]}}}"#,
            #"{"type":"graph_edge","edge":{"from":"v1_coverage","to":"synthesis","kind":"judges","label":"objections(1)"}}"#,
            #"{"type":"graph_node","node":{"id":"v1_sources","kind":"verdict","title":"Sources critic","parent_ids":[],"depth":3,"round":1,"status":"pass","origin":"derived","meta":{"lens":"sources","objections":[]}}}"#])
        let filed = graph.node("v1_coverage")

        XCTAssertEqual(filed?.kind, .verdict)
        XCTAssertEqual(filed?.state, .judged(objections: 1))
        XCTAssertEqual(filed?.objections.map(\.followup), ["find Acme's 2025 published pricing page"])
        XCTAssertEqual(filed?.objections.first?.severity, "blocking")
        XCTAssertEqual(graph.node("v1_sources")?.state, .judged(objections: 0))
        XCTAssertEqual(graph.edges(of: .judges).map(\.to), ["synthesis"])
    }

    /// A verdict points at the answer rather than hanging under it, so collapsing or focusing one must not
    /// drag the answer and everything below it along.
    func testCollapsingAVerdictLeavesTheAnswerItJudgedOnTheCanvas() {
        let graph = fold([rootLine, angleLine, decomposesLine,
            #"{"type":"graph_node","node":{"id":"synthesis","kind":"synthesis","title":"Synthesis","parent_ids":[],"depth":2,"round":1,"status":"complete","origin":"derived"}}"#,
            #"{"type":"graph_edge","edge":{"from":"a1","to":"synthesis","kind":"synthesizes"}}"#,
            #"{"type":"graph_node","node":{"id":"v1_coverage","kind":"verdict","title":"Coverage critic","parent_ids":[],"depth":3,"round":1,"status":"pass","origin":"derived"}}"#,
            #"{"type":"graph_edge","edge":{"from":"v1_coverage","to":"synthesis","kind":"judges"}}"#])

        XCTAssertNotNil(graph.hiding(under: ["v1_coverage"]).node("synthesis"))
        XCTAssertEqual(graph.ancestry(of: "synthesis"), ["synthesis", "a1", "root"])
    }

    func testTheValidatedRunFixtureDrawsEveryRoundsVerdictsAgainstTheAnswer() throws {
        let url = Bundle.module.url(forResource: "run-validated-transcript", withExtension: "ndjson",
                                    subdirectory: "Fixtures")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("run-validated-transcript.ndjson fixture is not bundled")
        }
        let graph = fold(text.split(separator: "\n").map(String.init))
        let verdicts = graph.nodes(of: .verdict)

        XCTAssertEqual(verdicts.count, 8, "four validator tasks, two rounds")
        XCTAssertEqual(graph.edges(of: .judges).count, 8)
        XCTAssertTrue(graph.edges(of: .judges).allSatisfy { $0.to == "synthesis" })
        XCTAssertEqual(verdicts.filter { $0.state == .judged(objections: 0) }.count, 7)
        XCTAssertEqual(verdicts.first { $0.state == .judged(objections: 1) }?.objections.count, 1)
        XCTAssertEqual(graph.nodes.filter { $0.origin == .objection }.map(\.kind), [.question, .inquiry])
        XCTAssertEqual(graph.node("synthesis")?.kind, .synthesis)
    }

    /// PRD 08 R1 — the loop has to be readable off the canvas alone: which verdict objected, what question
    /// that objection became, and which round-2 inquiry exists because of it.
    func testAnObjectionsQuestionRunsFromTheVerdictThatFiledItIntoTheNextRound() throws {
        let url = Bundle.module.url(forResource: "run-validated-transcript", withExtension: "ndjson",
                                    subdirectory: "Fixtures")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("run-validated-transcript.ndjson fixture is not bundled")
        }
        let graph = fold(text.split(separator: "\n").map(String.init))
        let question = try XCTUnwrap(graph.nodes.first { $0.origin == .objection && $0.kind == .question })
        let inquiry = try XCTUnwrap(graph.nodes.first { $0.origin == .objection && $0.kind == .inquiry })

        XCTAssertEqual(graph.children(of: "v1_coverage").map(\.id), [question.id])
        XCTAssertEqual(graph.children(of: question.id).map(\.id), [inquiry.id])
        XCTAssertEqual(inquiry.round, 2)
        XCTAssertEqual(graph.ancestry(of: inquiry.id), [inquiry.id, question.id, "v1_coverage"])
        XCTAssertEqual(graph.node("v1_coverage")?.lens, "coverage")
        XCTAssertEqual(question.reason, "the answer never states 2025 pricing")
    }

    /// The lens is the word on the wire between a verdict and the question it raised, so an edge drawn from
    /// `parent_ids` before the labelled one arrives must take the label rather than shut it out.
    func testTheWireFromAVerdictToItsQuestionCarriesTheLensThatFiledIt() {
        let graph = fold([rootLine,
            #"{"type":"graph_node","node":{"id":"v1_coverage","kind":"verdict","title":"Coverage critic","parent_ids":[],"depth":3,"round":1,"status":"objections(1)","origin":"derived","meta":{"lens":"coverage","objections":[]}}}"#,
            #"{"type":"graph_node","node":{"id":"q1","kind":"question","title":"find the 2025 pricing page","parent_ids":["v1_coverage"],"depth":1,"round":1,"status":"approved","origin":"objection","meta":{"lens":"coverage","statement":"the answer never states 2025 pricing","severity":"blocking"}}}"#,
            #"{"type":"graph_edge","edge":{"from":"v1_coverage","to":"q1","kind":"spawned","label":"coverage"}}"#])

        XCTAssertEqual(graph.edges(of: .spawned).map(\.label), ["coverage"])
    }

    func testTheEngineRunFixtureFoldsIntoAConnectedGraph() throws {
        let url = Bundle.module.url(forResource: "run-transcript", withExtension: "ndjson",
                                    subdirectory: "Fixtures")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("run-transcript.ndjson fixture is not bundled")
        }
        let graph = fold(text.split(separator: "\n").map(String.init))

        XCTAssertNotNil(graph.node("root"))
        XCTAssertFalse(graph.nodes(of: .inquiry).isEmpty)
        XCTAssertFalse(graph.edges(of: .decomposes).isEmpty)
        XCTAssertTrue(graph.nodes.allSatisfy { !$0.title.isEmpty })
    }
}
