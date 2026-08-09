import XCTest
@testable import QuorumCore

/// The richer mock transcript that drives the dev-only "Mock TS core" toggle must reduce through the same
/// `RunStreamParser` the live engine uses — exercising the shapes a happy-path golden run doesn't: two
/// rounds, a halted angle, and a synthesis carrying conflicts + gaps. If the fixture is mis-authored or the
/// parser stops handling one of these, this fails.
final class MockRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-run.ndjson")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    func testRicherTranscriptReducesAcrossRoundsWithHaltAndConflicts() throws {
        let all = try lines()

        var plans = 0, rounds = 0, activity = 0
        var research: [TopicFindings] = []
        var syntheses: [TopicFindings] = []
        var runResultTopics = 0

        for line in all {
            guard let ev = RunStreamParser.parse(line) else {
                XCTFail("mock transcript emitted a line the parser rejected: \(line)"); continue
            }
            switch ev {
            case .plan(let a): plans += 1; XCTAssertEqual(a.count, 2)
            case .round(let r, let a): rounds += 1; XCTAssertEqual(r, 2); XCTAssertEqual(a.count, 1)
            case .activity: activity += 1
            case .topicResult(let tr):
                tr.role == "synthesis" ? syntheses.append(tr.toFindings()) : research.append(tr.toFindings())
            case .runResult(let rr): runResultTopics = rr.topics.count
            default: break
            }
        }

        XCTAssertEqual(plans, 1, "round 1 is announced with a plan event")
        XCTAssertEqual(rounds, 1, "round 2 is announced with a round event")
        XCTAssertGreaterThanOrEqual(activity, 3, "each round's angles stream live, routed by angle_id")

        XCTAssertEqual(research.count, 3, "a1 + a2 (round 1) + a3 (round 2)")
        XCTAssertEqual(research.filter { $0.status == .haltedSpend }.count, 1, "one angle halted on its spend cap")
        XCTAssertEqual(research.filter { $0.status == .complete }.count, 2)

        XCTAssertEqual(syntheses.count, 2, "one synthesis per round")
        XCTAssertTrue(syntheses.contains { !$0.conflicts.isEmpty && !$0.gaps.isEmpty },
                      "round 1's synthesis surfaces conflicts and gaps its fenced json carried")

        XCTAssertEqual(runResultTopics, 4, "3 angles + the final synthesis")
    }

    /// The offline demo's contract (PRD 03): the mock transcript must promise only evidence that is
    /// actually on disk, and every resolved offset must select the quote it claims. A mis-authored
    /// fixture would otherwise ship a reader that highlights the wrong text — the one failure mode the
    /// whole feature exists to prevent.
    func testMockTranscriptCarriesEvidenceWhoseOffsetsSelectTheQuote() throws {
        var documents: [SourceDocument] = []
        var citations: [Citation] = []
        var markerIDs: Set<String> = []

        for line in try lines() {
            switch RunStreamParser.parse(line) {
            case .document(_, let doc): documents.append(doc)
            case .topicResult(let tr):
                citations.append(contentsOf: tr.evidence.citations)
                markerIDs.formUnion(CitationMarkers.ids(in: tr.result))
            default: break
            }
        }

        XCTAssertEqual(documents.count, 3, "two captured sources plus one deliberately un-snapshotted")
        XCTAssertFalse(markerIDs.isEmpty, "the mock writeups carry per-sentence markers")

        let index = EvidenceIndex(documents: documents, citations: citations)
        for id in markerIDs {
            XCTAssertNotNil(index.citation(id), "marker [^\(id)] has no citation behind it")
        }

        let pdf = documents.first { $0.contentType == .pdf }
        XCTAssertNotNil(pdf?.originalPath, "the PDF source keeps its original bytes for PDFKit")
        XCTAssertTrue(documents.contains { !$0.hasSnapshot },
                      "one source stays un-snapshotted so the 'not verifiable' path is demoable")

        for citation in citations {
            guard let document = index.document(for: citation) else {
                XCTFail("citation \(citation.id) names a source the run never registered"); continue
            }
            guard let range = citation.snapshotRange else {
                XCTAssertFalse(document.hasSnapshot,
                               "\(citation.id) resolved to no span, so its source must have no snapshot")
                continue
            }
            let text = try snapshotText(document)
            let utf16 = Array(text.utf16)
            XCTAssertLessThanOrEqual(range.upperBound, utf16.count, "\(citation.id) points past its snapshot")
            let selected = String(decoding: utf16[range.lowerBound..<range.upperBound], as: UTF16.self)
            XCTAssertEqual(folded(selected), folded(citation.quote),
                           "\(citation.id) offsets select text that is not its quote")
        }
    }

    private func folded(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func snapshotText(_ document: SourceDocument) throws -> String {
        let name = URL(fileURLWithPath: document.snapshotPath ?? "").lastPathComponent
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-sources")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
