import XCTest
@testable import QuorumCore

final class MockRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        try String(contentsOf: EngineFixtures.mockRun, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    private func events() throws -> [RunStreamParser.Event] {
        try lines().map { line in
            guard let event = RunStreamParser.parse(line) else {
                XCTFail("the mock transcript emitted a line the parser rejected: \(line.prefix(200))")
                return .other
            }
            return event
        }
    }

    private func runResult() throws -> RunStreamParser.RunResultEvent {
        let result = try events().compactMap { event -> RunStreamParser.RunResultEvent? in
            if case .runResult(let result) = event { return result }
            return nil
        }.last
        return try XCTUnwrap(result, "the transcript never reports a run_result")
    }

    private func topicResults() throws -> [RunStreamParser.TopicResultEvent] {
        try events().compactMap { event in
            if case .topicResult(let topic) = event { return topic }
            return nil
        }
    }

    func testTheTranscriptSpeaksTheProtocolTheAppWasBuiltAgainst() throws {
        let start = try events().first
        guard case .runStart(let sessionID, let version, let grounding) = start else {
            return XCTFail("the first line must be the run_start handshake, was \(String(describing: start))")
        }
        XCTAssertFalse(sessionID.isEmpty)
        XCTAssertEqual(version, RunStreamParser.supportedProtocolVersion)
        XCTAssertEqual(grounding, .captured, "the demo captures snapshots, so its chips may read as verified")
    }

    func testAnEventTypeTheParserHasNeverHeardOfIsToleratedRatherThanFatal() throws {
        let unknown = try lines().filter { $0.contains("\"type\": \"heartbeat\"") || $0.contains("\"type\":\"heartbeat\"") }
        XCTAssertEqual(unknown.count, 1, "the transcript carries one forward-compatibility line")
        XCTAssertEqual(RunStreamParser.parse(try XCTUnwrap(unknown.first)), .other)
    }

    func testEveryTopicLifecycleTheAppCanDrawIsExercised() throws {
        let research = try topicResults().filter { $0.role == "research" }.map { $0.toFindings() }
        XCTAssertEqual(Set(research.map(\.status)), [.complete, .error, .haltedSpend, .inconclusive],
                       "an errored angle, a spend-capped one and an empty-handed one all reach the canvas")

        let statuses = try events().compactMap { event -> String? in
            if case .angleStatus(_, let status) = event { return status }
            return nil
        }
        XCTAssertEqual(Set(statuses), ["running", "complete", "error", "halted"])

        let syntheses = try topicResults().filter { $0.role == "synthesis" }
        XCTAssertEqual(syntheses.count, 4, "three rounds redraft the answer, then one reconciliation fuses them")
        XCTAssertEqual(syntheses.filter(\.reconciled).count, 1, "only the fused answer is the current one")
        XCTAssertEqual(syntheses.last?.reconciled, true, "the fused answer is the last thing the run says")
        XCTAssertTrue(try topicResults().allSatisfy(\.isResumable),
                      "the demo runs on the CLI backend, so every topic can be reopened in chat")
    }

    func testTheLoopBuysThreeRoundsAndAnswersEachRoundItBought() throws {
        var planned: [Int: [String]] = [:]
        for event in try events() {
            switch event {
            case .plan(let angles):          planned[1] = angles.map(\.angleID)
            case .round(let n, let angles):  planned[n] = angles.map(\.angleID)
            default: break
            }
        }
        XCTAssertEqual(planned[1]?.count, 4, "the plan the reader approves is four angles wide")
        XCTAssertEqual(planned[2], ["x3", "x4"], "round 2 is the frontier the round-1 objections bought")
        XCTAssertEqual(planned[3], ["x5"], "round 3 chases the one objection round 2 left blocking")
        XCTAssertEqual(planned.count, 3)
    }

    func testTheGraphGrowsSpawnsVerdictsAndOneReconciledAnswer() throws {
        var graph = ResearchGraph()
        var questionStates: Set<QuestionState> = []
        for event in try events() {
            graph.apply(event)
            for node in graph.nodes(of: .question) {
                if case .asked(let state) = node.state { questionStates.insert(state) }
            }
        }

        XCTAssertEqual(questionStates, [.approved, .pending, .rejected, .expired],
                       "every verdict a raised question can end on is drawn at some point in the run")
        XCTAssertNotNil(graph.node("r1")?.reason, "a question the gate refused carries the reason it was refused")
        XCTAssertEqual(graph.node("q2")?.state, .asked(.expired),
                       "an offer nobody ruled on expires rather than holding the run open")

        let origins = Set(graph.nodes(of: .inquiry).map(\.origin))
        XCTAssertEqual(origins, [.planner, .spawn, .objection],
                       "planned angles, an approved mid-run spawn and objection-born rounds all became work")

        let verdicts = graph.nodes(of: .verdict)
        XCTAssertEqual(Set(verdicts.map(\.round)), [1, 2, 3])
        XCTAssertTrue(verdicts.contains { $0.state == .judged(objections: 0) }, "a task that passed")
        XCTAssertTrue(verdicts.contains { $0.state == .judged(objections: 1) }, "a task that filed something")
        XCTAssertTrue(verdicts.contains { $0.state == .derived },
                      "a validator task the run could not afford reads as skipped, never as a pass")
        XCTAssertEqual(Set(verdicts.compactMap(\.lens)),
                       ["claim_sweep", "coverage", "conflicts", "sources", "structure"])
        XCTAssertTrue(graph.edges(of: .judges).allSatisfy { $0.to == "synthesis" },
                      "every verdict points back at the answer it read")

        let answer = try XCTUnwrap(graph.answer)
        XCTAssertEqual(answer.id, "reconciliation")
        XCTAssertTrue(graph.children(of: answer.id).isEmpty,
                      "the answer is where the canvas opens, not a parent of its own critics")

        XCTAssertFalse(graph.edges(of: .corroborates).isEmpty,
                       "sources two angles reached independently are what the fan-out exists to produce")
        XCTAssertGreaterThan(graph.sourceConvergence, 0.3)
    }

    func testTheAnswerIsJudgedThreeTimesAndStillCarriesOneStandingObjection() throws {
        let validation = try XCTUnwrap(runResult().validation)
        XCTAssertEqual(validation.status, "validated", "the claim sweep ran in every round")
        XCTAssertFalse(validation.holds, "the last round still found a claim its own quotes do not carry")
        XCTAssertEqual(validation.rounds, 3)
        XCTAssertEqual(validation.blocking, 4)
        XCTAssertEqual(validation.objectionsAdmitted, 3)
        XCTAssertEqual(validation.objectionsOutstanding.count, 1)
        XCTAssertEqual(validation.objectionsOutstanding.first?.severity, "blocking")
        XCTAssertFalse(try XCTUnwrap(validation.objectionsOutstanding.first?.followup).isEmpty,
                       "an objection that names no researchable task would have been discarded")
        XCTAssertEqual(validation.unsupportedCitationIDs, ["a2c1"])
        XCTAssertGreaterThan(validation.spendUSD, 0, "judging the answer costs money and lands on the ledger")
        XCTAssertEqual(try runResult().status, "inconclusive",
                       "a standing blocking objection is reported honestly, not rounded up to complete")
    }

    func testAQuoteTheSweepRejectedIsBadgedRatherThanTheWholeAnswer() throws {
        let result = try runResult()
        let evidence = result.topics
            .reduce(result.evidence) { $0.merging($1.evidence) }
            .marking(unsupported: try XCTUnwrap(result.validation).unsupportedCitationIDs)
        XCTAssertEqual(evidence.tier("a2c1"), .unsupported, "located, but it does not carry its claim")
        XCTAssertEqual(evidence.tier("x4c1"), .supported)
        XCTAssertEqual(evidence.tier("a2c2"), .close, "a fuzzy hit in a degraded capture is a close match")
        XCTAssertEqual(evidence.tier("a4c1"), .unresolved, "nothing was captured to check this one against")
    }

    func testEveryCaptureOutcomeTheReaderCanRenderIsPresent() throws {
        let documents = try runResult().evidence.documents
        XCTAssertEqual(documents.count, 7)
        XCTAssertEqual(Set(documents.map(\.capture)), [.ok, .degraded, .failed])

        let paginated = try XCTUnwrap(documents.first { $0.contentType == .pdf })
        XCTAssertNotNil(paginated.originalPath, "the PDF keeps its original bytes for PDFKit")
        XCTAssertEqual(paginated.pageOffsets.count, 3, "its extraction carries page separators, so pages are known")

        XCTAssertEqual(documents.filter { !$0.hasSnapshot }.count, 2,
                       "one fetch failed and one url was only ever seen in search results")
        XCTAssertTrue(documents.contains { $0.capture == .degraded && $0.hasSnapshot },
                      "tag soup is still kept — a fuzzy hit in it is honest, an exact one is not")
    }

    func testEveryMarkerResolvesAndEveryOffsetSelectsTheQuoteItClaims() throws {
        var documents: [SourceDocument] = []
        var citations: [Citation] = []
        var markerIDs: Set<String> = []
        for event in try events() {
            switch event {
            case .document(_, let document):
                documents.append(document)
            case .topicResult(let topic):
                citations.append(contentsOf: topic.evidence.citations)
                markerIDs.formUnion(CitationMarkers.ids(in: topic.result))
            default:
                break
            }
        }
        let index = EvidenceIndex(documents: documents, citations: citations)
        XCTAssertGreaterThanOrEqual(markerIDs.count, 12, "the demo's prose is cited sentence by sentence")
        XCTAssertEqual(Set(citations.map(\.match)), [.exact, .normalized, .fuzzy, .unresolved],
                       "every rung of the match ladder is on screen somewhere")

        for id in markerIDs.sorted() {
            XCTAssertNotNil(index.citation(id), "marker [^\(id)] has no citation behind it")
        }
        for citation in citations {
            let document = try XCTUnwrap(index.document(for: citation),
                                         "\(citation.id) names a source the run never registered")
            guard let range = citation.snapshotRange else {
                XCTAssertEqual(citation.match, .unresolved,
                               "\(citation.id) resolved to no span, so it must read as unverifiable")
                continue
            }
            let text = try snapshotText(document)
            let utf16 = Array(text.utf16)
            XCTAssertLessThanOrEqual(range.upperBound, utf16.count, "\(citation.id) points past its snapshot")
            let selected = String(decoding: utf16[range.lowerBound..<range.upperBound], as: UTF16.self)
            switch citation.match {
            case .exact:
                XCTAssertEqual(folded(selected), folded(citation.quote),
                               "\(citation.id) offsets select text that is not its quote")
            case .normalized:
                XCTAssertEqual(flattened(selected), flattened(citation.quote),
                               "\(citation.id) is not a case/whitespace variant of the span it points at")
                XCTAssertNotEqual(selected, citation.quote,
                                  "\(citation.id) matches verbatim, so it should be reported as exact")
            case .fuzzy:
                XCTAssertGreaterThanOrEqual(overlap(selected, citation.quote), 0.6,
                                            "\(citation.id) points at a window its quote does not come from")
            case .unresolved:
                XCTFail("\(citation.id) resolved to a span while claiming to be unresolved")
            }
            if let page = citation.page {
                XCTAssertEqual(document.page(containing: range.lowerBound), page,
                               "\(citation.id) is labelled with a page its offset does not fall on")
            }
        }
    }

    func testTheFusedAnswerDropsWhatTheLaterRoundOverturned() throws {
        let syntheses = try topicResults().filter { $0.role == "synthesis" }
        let firstDraft = try XCTUnwrap(syntheses.first).toFindings()
        let fused = try XCTUnwrap(syntheses.last).toFindings()

        XCTAssertTrue(firstDraft.writeupMarkdown.contains("expires five minutes after it is written"),
                      "round 1 has to be wrong about something for reconciliation to have work to do")
        XCTAssertFalse(fused.writeupMarkdown.contains("expires five minutes after it is written"),
                       "a claim a later round corrected does not survive into the current answer")
        XCTAssertTrue(fused.writeupMarkdown.contains("resets the countdown"),
                      "the correction is what the fused answer leads with")
        XCTAssertFalse(fused.conflicts.isEmpty, "a conflict nothing settled stays flagged rather than smoothed")
        XCTAssertTrue(fused.writeupMarkdown.contains("## Validation"),
                      "the fused answer carries what still stands against it")
        XCTAssertTrue(firstDraft.writeupMarkdown.contains("## Citation check"),
                      "the round that cited an untraceable url says so in the prose")
    }

    func testTheWholeDemoFoldsIntoOneReportTheBrainCanKeep() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let persistence = EngineRunPersistence(question: "Where does prompt caching pay off?",
                                               config: standardRun(project: project), store: store,
                                               runDir: runDir, priorNotes: [])
        for event in try events() { persistence.apply(event, at: fixedStart) }
        persistence.flush(at: fixedStart)

        let entries = persistence.entries
        let syntheses = entries.filter { $0.isSynthesis == true }
        XCTAssertEqual(syntheses.count, 4, "one filed answer per round, plus the fused one")
        XCTAssertEqual(syntheses.last?.noteAction, .reconciled,
                       "the dive ends on one current answer rather than a fourth round log")
        XCTAssertEqual(entries.filter { $0.isSynthesis != true }.count, 8,
                       "four planned angles, one approved spawn and three objection-born rounds")
        XCTAssertNotNil(syntheses.last?.notePath, "the current answer reaches the brain as a note")

        let validation = try XCTUnwrap(persistence.validation)
        XCTAssertEqual(validation.verdicts.count, 13,
                       "four tasks judge every round, plus the structure objection round 1 filed itself")
        XCTAssertEqual(validation.verdicts.filter { $0.status == "skipped" }.count, 3,
                       "round 3's critics could not run, and a task that did not run never reads as a pass")
        XCTAssertEqual(validation.byRound.map(\.number), [1, 2, 3])
        XCTAssertFalse(try XCTUnwrap(validation.byRound.last).holds)
    }

    private func folded(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func flattened(_ s: String) -> String {
        folded(s).lowercased()
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
    }

    private func overlap(_ a: String, _ b: String) -> Double {
        let left = Set(folded(a).lowercased().split(separator: " "))
        let right = Set(folded(b).lowercased().split(separator: " "))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return 2 * Double(left.intersection(right).count) / Double(left.count + right.count)
    }

    private func snapshotText(_ document: SourceDocument) throws -> String {
        let name = URL(fileURLWithPath: document.snapshotPath ?? "").lastPathComponent
        return try String(contentsOf: EngineFixtures.mockSource(name), encoding: .utf8)
    }
}
