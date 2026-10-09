import SwiftUI
import AppKit
import QuorumCore

/// Dev-only: the canvas as a PNG. `swift run Quorum --snapshot out.png` rebuilds a three-round run with a
/// full validator quorum the way History does and renders the real view, so a change to how the graph
/// reads can be looked at without driving the app by hand.
@MainActor
enum GraphSnapshot {
    static func write(to path: String, width: CGFloat = 1900, height: CGFloat = 2100) -> Bool {
        let renderer = ImageRenderer(content:
            ResearchGraphView(graph: .from(report: threeRounds), scrolls: false)
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static let question = "Does caching a prompt prefix pay for a bursty chat product?"

    private static var threeRounds: RunReport {
        RunReport(startedAt: .distantPast, finishedAt: .distantPast,
                  entries: [
                    angle("a1", "How the two vendors price a cached prefix",
                          headline: "Two price sheets, one trade: premium to write, discount to read",
                          findings: 10, cost: 1.4),
                    angle("a2", "What teams report after switching it on",
                          headline: "One instrumented sample says 52%, and it self-selected",
                          findings: 10, cost: 1.9),
                    angle("a3", "Failure modes: stampedes, cold starts and what breaks at scale",
                          headline: "Starting on the failure modes rather than the savings: a cache is a "
                                  + "shared resource, and the ways it goes wrong are not priced",
                          findings: 6, cost: 0.31, status: .error),
                    angle("a4", "Break-even arithmetic for a bursty product",
                          headline: "Break-even is a ratio; the window turns it into a traffic question",
                          findings: 7, cost: 3.0),
                    angle("a5", "The hit-rate distribution behind the 52% was never published",
                          headline: "The hit-rate distribution behind the 52% was never published",
                          findings: 7, cost: 1.1),
                    synthesis("s1", headline: "Pays when traffic clusters; the threshold is still unnamed",
                              gaps: 13, cost: 1.6),
                    angle("b1", "Does a cache read refresh the window, or does it run from the write?",
                          headline: "The window refreshes on read — round 1 had it backwards",
                          findings: 8, round: 2, cost: 1.2),
                    angle("b2", "What happens below a 40% hit rate",
                          headline: "Nothing measurable below a 40% hit rate", findings: 9, round: 2,
                          cost: 1.3),
                    synthesis("s2", headline: "Pays above a 40% hit rate; the window refreshes on read",
                              gaps: 12, round: 2, cost: 1.7),
                    angle("c1", "Is the 1-hour window ever worth its 2x write premium?",
                          headline: "Nobody has measured it; the choice stays a judgement about traffic",
                          findings: 9, round: 3, cost: 0.98),
                    synthesis("s3", headline: "Pays above a 40% hit rate; window size is still unmeasured",
                              gaps: 12, round: 3, cost: 1.6),
                    synthesis("s4", headline: "Pays above a 40% hit rate; the 52% is not a promise for "
                                            + "bursty traffic", gaps: 13, cost: 1.5, reconciled: true),
                  ],
                  totalCostUSD: 17.6, runSpendCapUSD: 40,
                  validation: RunValidation(
                    status: "objections", holds: false, blocking: 2, spendUSD: 2.1, rounds: 3,
                    objectionsAdmitted: 6, objectionsResolved: 4, objectionsOutstanding: [],
                    verdicts: quorum()))
    }

    /// The same five lenses judging each draft — the picture the canvas has to survive is a quorum this
    /// wide filing against three rounds of one answer.
    private static func quorum() -> [RunValidation.Verdict] {
        [
            verdict(1, "claim_sweep", "the claim \"A cached prefix expires five minutes after it is "
                                    + "written\" is misquoted by the source it cites"),
            verdict(1, "coverage", "the answer never says at what hit rate the trade turns negative, "
                                 + "which is the only number that was asked for"),
            verdict(1, "conflicts", nil),
            verdict(1, "sources", "the 52% figure is load-bearing and rests on one self-selected report "
                                + "plus one blog post"),
            verdict(1, "structure", "a3 returned no machine-readable summary, so none of its quotes "
                                  + "could be grounded"),
            verdict(2, "claim_sweep", nil),
            verdict(2, "coverage", nil),
            verdict(2, "conflicts", "a1 reads the 2x write premium as almost never worth it while a2's "
                                  + "practitioners report the opposite"),
            verdict(2, "sources", "the break-even figure and the low-hit-rate band now both rest on the "
                                + "same single report"),
            verdict(3, "claim_sweep", "the claim \"caching roughly halves input spend for a bursty chat "
                                    + "product\" is unsupported by any captured source"),
            skipped(3, "coverage"), skipped(3, "conflicts"), skipped(3, "sources"),
        ]
    }

    private static func verdict(_ round: Int, _ lens: String, _ objection: String?)
        -> RunValidation.Verdict {
        RunValidation.Verdict(
            id: "v\(round)_\(lens)", lens: lens, title: lens.replacingOccurrences(of: "_", with: " "),
            round: round, status: objection == nil ? "pass" : "objections(1)",
            objections: objection.map {
                [RunStreamParser.ObjectionEvent(lens: lens, statement: $0,
                                                severity: round == 1 ? "blocking" : "minor",
                                                followup: "settle it in the next round")]
            } ?? [])
    }

    private static func skipped(_ round: Int, _ lens: String) -> RunValidation.Verdict {
        RunValidation.Verdict(id: "v\(round)_\(lens)", lens: lens,
                              title: lens.replacingOccurrences(of: "_", with: " "), round: round,
                              status: "skipped", objections: [])
    }

    private static func angle(_ id: String, _ title: String, headline: String, findings: Int,
                              round: Int = 1, cost: Decimal,
                              status: TopicStatus = .complete) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: title, status: status, preset: .standard, headline: headline,
            confidenceSummary: "", sourcesConsulted: findings, costUSD: cost, durationSeconds: 60,
            note: nil, notePath: nil, transcriptPath: nil, round: round,
            findings: (1...findings).map {
                Finding(claim: "\(title) finding \($0)", sources: ["https://example.com/\(id)-\($0)"],
                        confidence: .high)
            })
    }

    private static func synthesis(_ id: String, headline: String, gaps: Int, round: Int? = nil,
                                  cost: Decimal, reconciled: Bool = false) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: question, status: .complete, preset: .standard, headline: headline,
            confidenceSummary: "", sourcesConsulted: 0, costUSD: cost, durationSeconds: 60,
            note: nil, notePath: nil, noteAction: reconciled ? .reconciled : nil, transcriptPath: nil,
            isSynthesis: true, gaps: (1...gaps).map { "open question \($0)" }, round: round)
    }
}
