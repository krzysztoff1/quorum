import XCTest
@testable import QuorumCore

/// The canvas talking back to a run that is already going: a verdict on an offer it made, a branch dropped
/// before it costs anything, a failed inquiry re-filed. Driven over a fake that reads exactly what the app
/// writes on the engine's stdin and answers with the engine's own stdout lines, so a control that never
/// reaches the wire — or an answer the graph ignores — fails here rather than in front of a person.
final class RunSteeringTests: XCTestCase {

    private let rootLine = """
    {"type":"graph_node","node":{"id":"root","kind":"question","title":"How should we price it?",\
    "parent_ids":[],"depth":0,"round":1,"status":"approved","origin":"root"}}
    """
    private let angleLine = """
    {"type":"graph_node","node":{"id":"a1","kind":"inquiry","title":"Competitor pricing",\
    "parent_ids":["root"],"depth":1,"round":1,"status":"running","origin":"planner"}}
    """
    private let offerLine = """
    {"type":"graph_node","node":{"id":"q1","kind":"question","title":"What did the 2024 filing say?",\
    "parent_ids":["a1"],"depth":2,"round":1,"status":"pending","origin":"spawn",\
    "meta":{"why":"a1 hit a paywall","provoked_by":"s3f9a1c2","est_cost_usd":2.5}}}
    """

    private func engine(_ lines: [String]) -> ScriptedEngine {
        let engine = ScriptedEngine()
        engine.emit(lines)
        return engine
    }

    // MARK: what goes down the pipe

    func testAVerdictOnAnOfferGoesDownTheSamePipeTheConfigWentDown() {
        let engine = self.engine([rootLine, angleLine, offerLine])

        engine.channel.send(.approve(id: "q1"))
        engine.channel.send(.reject(id: "q1"))

        XCTAssertEqual(engine.written, [
            #"{"type":"approve","id":"q1","verdict":"approved"}"#,
            #"{"type":"approve","id":"q1","verdict":"rejected"}"#,
        ])
        XCTAssertEqual(engine.received, [.approve(id: "q1"), .reject(id: "q1")])
    }

    func testPruningNamesTheBranchAndNothingElse() {
        let engine = self.engine([rootLine, angleLine])

        engine.channel.send(.prune(id: "a1"))

        XCTAssertEqual(engine.written, [#"{"type":"prune","id":"a1"}"#])
        XCTAssertEqual(engine.received, [.prune(id: "a1")])
    }

    func testRetryNamesTheInquiryToRunAgain() {
        let engine = self.engine([rootLine, angleLine])

        engine.channel.send(.retry(id: "a1"))

        XCTAssertEqual(engine.written, [#"{"type":"retry","id":"a1"}"#])
        XCTAssertEqual(engine.received, [.retry(id: "a1")])
    }

    func testAClosedChannelSaysNothingMore() {
        let engine = self.engine([rootLine, angleLine])

        engine.channel.close()
        engine.channel.send(.prune(id: "a1"))

        XCTAssertEqual(engine.written, [])
    }

    func testAControlLineThatMeansNothingIsNotAControl() {
        XCTAssertNil(RunControl.parse(#"{"type":"approve","verdict":"approved"}"#))
        XCTAssertNil(RunControl.parse(#"{"type":"shrug","id":"a1"}"#))
        XCTAssertNil(RunControl.parse("not json"))
        XCTAssertNil(RunControl.parse("   "))
    }

    // MARK: the round trip — what the engine answers lands on the canvas

    func testTheOfferTheUserApprovedComesBackAsAnInquiryThatIsRunning() {
        let engine = self.engine([rootLine, angleLine, offerLine])
        engine.script[.approve(id: "q1")] = [
            #"{"type":"graph_node_update","id":"q1","status":"approved"}"#,
            """
            {"type":"graph_node","node":{"id":"x1","kind":"inquiry","title":"The 2024 filing",\
            "parent_ids":["q1"],"depth":2,"round":1,"status":"running","origin":"spawn"}}
            """,
        ]

        engine.channel.send(.approve(id: "q1"))

        XCTAssertEqual(engine.graph.node("q1")?.state, .asked(.approved))
        XCTAssertEqual(engine.graph.node("x1")?.state, .worked(.running))
        XCTAssertEqual(engine.graph.node("a1")?.state, .worked(.running), "the wave carries on around the offer")
    }

    func testThePrunedBranchComesBackRefusedRatherThanSilentlyDropped() {
        let engine = self.engine([rootLine, angleLine, offerLine])
        engine.script[.prune(id: "q1")] = [
            #"{"type":"graph_node_update","id":"q1","status":"rejected"}"#,
        ]

        engine.channel.send(.prune(id: "q1"))

        XCTAssertEqual(engine.graph.node("q1")?.state, .asked(.rejected))
    }

    func testTheRetriedInquiryComesBackQueuedForTheNextWave() {
        let engine = self.engine([rootLine, angleLine])
        engine.script[.retry(id: "a1")] = [
            #"{"type":"graph_node_update","id":"a1","status":"queued"}"#,
        ]

        engine.channel.send(.retry(id: "a1"))

        XCTAssertEqual(engine.graph.node("a1")?.state, .worked(.queued))
    }

    // MARK: what the canvas does the instant the button is pressed

    func testApprovingMovesTheCardBeforeTheEngineAnswers() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine, offerLine] { graph.apply(RunStreamParser.parse(line)!) }

        graph.steer(.approve(id: "q1"))

        XCTAssertEqual(graph.node("q1")?.state, .asked(.approved))
    }

    func testPruningABranchWithdrawsEveryOfferStandingUnderIt() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine, offerLine] { graph.apply(RunStreamParser.parse(line)!) }
        graph.apply(RunStreamParser.parse("""
        {"type":"graph_node","node":{"id":"x1","kind":"inquiry","title":"The 2024 filing",\
        "parent_ids":["a1"],"depth":2,"round":1,"status":"queued","origin":"spawn"}}
        """)!)

        graph.steer(.prune(id: "a1"))

        XCTAssertEqual(graph.node("q1")?.state, .asked(.rejected))
        XCTAssertEqual(graph.node("x1")?.state, .worked(.queued), "work the run already took up is not undone")
        XCTAssertEqual(graph.node("a1")?.state, .worked(.running), "pruning a branch leaves it working")
    }

    func testTheBranchTravelsAsOneLinePerOfferBecauseTheEngineRulesOnOne() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine, offerLine] { graph.apply(RunStreamParser.parse(line)!) }
        graph.apply(RunStreamParser.parse("""
        {"type":"graph_node","node":{"id":"q2","kind":"question","title":"And the 2023 one?",\
        "parent_ids":["a1"],"depth":2,"round":1,"status":"pending","origin":"spawn"}}
        """)!)

        XCTAssertEqual(graph.pendingOffers(under: "a1").map(\.id), ["q1", "q2"])
        XCTAssertEqual(graph.pendingOffers(under: "q1").map(\.id), ["q1"])
        XCTAssertEqual(graph.pendingOffers(under: "root").map(\.id), ["q1", "q2"])
    }

    func testPruningCannotUnpayForWorkThatAlreadyFinished() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine] { graph.apply(RunStreamParser.parse(line)!) }
        graph.apply(RunStreamParser.parse(#"{"type":"graph_node_update","id":"a1","status":"complete"}"#)!)

        graph.steer(.prune(id: "a1"))

        XCTAssertEqual(graph.node("a1")?.state, .worked(.complete))
    }

    func testPruningLeavesATopicAlreadyInFlightTheStateItEarned() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine] { graph.apply(RunStreamParser.parse(line)!) }

        graph.steer(.prune(id: "a1"))

        XCTAssertEqual(graph.node("a1")?.state, .worked(.running),
                       "neither the engine nor the canvas can unspend a topic that is running")
    }

    func testRetryPutsAFailedInquiryBackInTheQueue() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine] { graph.apply(RunStreamParser.parse(line)!) }
        graph.apply(RunStreamParser.parse(#"{"type":"graph_node_update","id":"a1","status":"error"}"#)!)

        graph.steer(.retry(id: "a1"))

        XCTAssertEqual(graph.node("a1")?.state, .worked(.queued))
    }

    // MARK: which steering a node is actually offered

    func testABranchIsOnlyPrunableWhileAnOfferUnderItIsStillStanding() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine, offerLine] { graph.apply(RunStreamParser.parse(line)!) }

        XCTAssertTrue(graph.canPrune("a1"), "its offer is still standing")
        XCTAssertTrue(graph.canPrune("q1"))

        graph.steer(.reject(id: "q1"))

        XCTAssertFalse(graph.canPrune("a1"), "the branch is already running and holds nothing unspent")
        XCTAssertFalse(graph.canPrune("q1"))
    }

    func testOnlyATopicThatStoppedCanBeRunAgain() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine] { graph.apply(RunStreamParser.parse(line)!) }

        XCTAssertFalse(graph.canRetry("a1"), "it is still running")
        XCTAssertFalse(graph.canRetry("root"), "a question is not a topic")

        graph.apply(RunStreamParser.parse(#"{"type":"graph_node_update","id":"a1","status":"error"}"#)!)

        XCTAssertTrue(graph.canRetry("a1"))
    }

    func testRetryLeavesAnInquiryThatIsStillRunningAlone() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine] { graph.apply(RunStreamParser.parse(line)!) }

        graph.steer(.retry(id: "a1"))

        XCTAssertEqual(graph.node("a1")?.state, .worked(.running))
    }

    func testAnythingAlreadyOnTheCanvasCanBeDugIntoWithoutARightClick() {
        var graph = ResearchGraph()
        for line in [rootLine, angleLine, offerLine] { graph.apply(RunStreamParser.parse(line)!) }

        XCTAssertTrue(graph.canDig("root"))
        XCTAssertTrue(graph.canDig("a1"))
        XCTAssertTrue(graph.canDig("q1"), "an offer is a place to research further from as much as any node")
        XCTAssertFalse(graph.canDig("never-arrived"))
    }
}

/// The engine on the other end of the pipe, as far as the app can tell: it reads the app's stdin lines and
/// answers with the stdout the run would have emitted for that control.
private final class ScriptedEngine {
    var script: [RunControl: [String]] = [:]
    private(set) var written: [String] = []
    private(set) var received: [RunControl] = []
    private(set) var graph = ResearchGraph()

    lazy var channel = RunControlChannel { [weak self] line in self?.read(line) }

    func emit(_ lines: [String]) {
        for line in lines {
            guard let event = RunStreamParser.parse(line) else { continue }
            graph.apply(event)
        }
    }

    private func read(_ line: String) {
        written.append(line)
        guard let control = RunControl.parse(line) else { return }
        received.append(control)
        emit(script[control] ?? [])
    }
}
