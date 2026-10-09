import XCTest
@testable import QuorumCore

final class NoteFootnoteTests: XCTestCase {

    private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func topic(_ id: String, headline: String, writeup: String, findings: [Finding]) -> TopicFindings {
        TopicFindings(id: id, status: .complete, preset: .standard, headline: headline, findings: findings,
                      sourcesConsulted: findings.count, costUSD: 0, duration: .seconds(1),
                      writeupMarkdown: writeup, transcript: "log \(id)", note: nil)
    }

    private let doordash = "https://careersatdoordash.com/blog/powering-search-recommendations-at-doordash/"
    private let secondMeasure = "https://secondmeasure.com/datapoints/food-delivery-services-grubhub-uber-eats-doordash-postmates/"
    private let legalit = "https://legalitgroup.com/en/gdpr-and-personalized-nutrition-apps/"
    private let mckinsey = "https://www.mckinsey.com/industries/retail/our-insights/personalizing-the-customer-experience-driving-differentiation-in-retail"

    private func referencedMarkers(in note: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\[\^([A-Za-z0-9_-]+)\](?!:)"#)
        let ns = note as NSString
        return Set(regex.matches(in: note, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
    }

    private func definitions(in note: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"(?m)^\[\^([A-Za-z0-9_-]+)\]: (.*)$"#)
        let ns = note as NSString
        var byID: [String: String] = [:]
        for match in regex.matches(in: note, range: NSRange(location: 0, length: ns.length)) {
            byID[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        return byID
    }

    func testASynthesisNoteDefinesEveryMarkerItBorrowedFromAnAngle() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let angles = [
            topic("a1", headline: "Architektura", writeup: "DoorDash started knowledge-based.[^c2]",
                  findings: [Finding(claim: "knowledge-based first", sources: [doordash], confidence: .high,
                                     citationIDs: ["c2"])]),
            topic("a2", headline: "ROI", writeup: "Retention varies.[^c5] McKinsey says 1-2%.[^c1]",
                  findings: [Finding(claim: "retention", sources: [secondMeasure], confidence: .medium,
                                     citationIDs: ["c5"]),
                             Finding(claim: "grocery lift", sources: [mckinsey], confidence: .high,
                                     citationIDs: ["c1"])]),
            topic("a3", headline: "Prawo", writeup: "Food logs are not special category.[^c1]",
                  findings: [Finding(claim: "special category", sources: [legalit], confidence: .high,
                                     citationIDs: ["c1"])]),
        ]
        let synthesis = topic("synthesis-1", headline: "Odpowiedź", writeup: """
            DoorDash zaczął od systemu opartego na wiedzy[^a1c2]. Subskrypcje mają zróżnicowaną retencję[^a2c5].

            ## Prawo

            Sam log jedzenia nie jest danymi specjalnej kategorii[^a3c1], a McKinsey podaje 1-2%[^a2c1].
            """, findings: [Finding(claim: "grocery lift", sources: [mckinsey], confidence: .medium,
                                   citationIDs: ["a2c1"])])

        let entries = persistFanOutRound(synthesis: synthesis, angleFindings: angles,
                                         angleTitles: ["Architektura", "ROI", "Prawo"], question: "Zrób research",
                                         config: RunSettings(projectURL: project, runSpendCapUSD: 40,
                                                             perTopicSpendCapUSD: 10,
                                                             perTopicTimeout: .seconds(60),
                                                             defaultPreset: .standard),
                                         store: store, runDir: runDir, priorNotes: [], round: nil,
                                         at: fixedStart, evidence: EvidenceIndex(grounding: .none))

        let notePath = try XCTUnwrap(entries.first { $0.isSynthesis == true }?.notePath)
        let note = try String(contentsOf: URL(fileURLWithPath: notePath), encoding: .utf8)
        let defined = definitions(in: note)
        XCTAssertEqual(referencedMarkers(in: note), ["a1c2", "a2c5", "a3c1", "a2c1"])
        for marker in referencedMarkers(in: note) {
            XCTAssertNotNil(defined[marker], "[^\(marker)] dangles in the exported note:\n\(note)")
        }
        XCTAssertTrue(try XCTUnwrap(defined["a1c2"]).contains(doordash))
        XCTAssertTrue(try XCTUnwrap(defined["a2c5"]).contains("[secondmeasure.com](\(secondMeasure))"),
                      "labelled by the host it links to")
        XCTAssertTrue(try XCTUnwrap(defined["a3c1"]).contains(legalit))
        XCTAssertTrue(try XCTUnwrap(defined["a2c1"]).contains(mckinsey))
        XCTAssertFalse(note.contains("no source was recorded"), note)
        XCTAssertTrue(note.contains("no evidence was captured"), "the note says its quotes went unchecked")

        let report = RunReport(startedAt: fixedStart, finishedAt: fixedStart, entries: entries,
                               totalCostUSD: 0, runSpendCapUSD: 40)
        XCTAssertTrue(Reporter.renderDigest(report).contains("- **Evidence:** ⚠️ not captured"),
                      Reporter.renderDigest(report))
    }

    func testARunThatCapturedEvidenceDoesNotClaimOtherwise() {
        let entry = RunReport.TopicEntry(id: "s", question: "Q", status: .complete, preset: .standard,
                                         headline: "H", confidenceSummary: "", sourcesConsulted: 0, costUSD: 0,
                                         durationSeconds: 0, note: nil, notePath: nil, transcriptPath: nil,
                                         isSynthesis: true)
        let report = RunReport(startedAt: fixedStart, finishedAt: fixedStart, entries: [entry],
                               totalCostUSD: 0, runSpendCapUSD: 40)
        XCTAssertFalse(Reporter.renderDigest(report).contains("**Evidence:**"))
    }

    func testAMarkerNoFindingAnywhereBacksStillGetsADefinitionSayingSo() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let synthesis = topic("s", headline: "Answer", writeup: "A claim nobody backed.[^a9c9]", findings: [])
        let entries = persistFanOutRound(synthesis: synthesis, angleFindings: [], angleTitles: [], question: "Q",
                                         config: RunSettings(projectURL: project, runSpendCapUSD: 40,
                                                             perTopicSpendCapUSD: 10,
                                                             perTopicTimeout: .seconds(60),
                                                             defaultPreset: .standard),
                                         store: store, runDir: runDir, priorNotes: [], round: nil, at: fixedStart)
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entries.first?.notePath)),
                              encoding: .utf8)
        XCTAssertNotNil(definitions(in: note)["a9c9"], note)
    }
}
