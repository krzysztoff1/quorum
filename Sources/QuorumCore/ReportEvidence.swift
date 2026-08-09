import Foundation

/// What one node hands the reader: the quotes its writeup can resolve, and the directory the snapshots
/// behind them were kept in. Hashable so it can ride along on a navigation value — and hashed by where it
/// came from and how much it holds, because a run's whole citation list is a lot of string to chew through
/// for an identity check that happens on every push.
public struct NodeEvidence: Sendable, Equatable, Hashable {
    public let index: EvidenceIndex
    public let directory: URL

    public init(index: EvidenceIndex, directory: URL) {
        self.index = index
        self.directory = directory
    }

    public var grounding: RunGrounding { index.grounding }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(directory)
        hasher.combine(index.documents.count)
        hasher.combine(index.citations.count)
    }
}

/// A finished run's evidence, read one node at a time and kept once read. The rail opens on a single node,
/// so a thirty-node run has no business assembling thirty citation indexes to show one of them — each is
/// built the first time something asks, and the answer's, which is every angle's registry merged, is built
/// once rather than on every redraw (PRD 09 R6).
public final class ReportEvidence {
    private let report: RunReport
    private var readings: [String: NodeEvidence?] = [:]

    public init(report: RunReport) {
        self.report = report
    }

    /// Which nodes' evidence is resident. A node nobody opened is absent, and a node that turned out to
    /// have kept nothing is remembered as such rather than re-derived on every redraw.
    public var loadedNodes: Set<String> { Set(readings.keys) }

    public func reading(for entryID: String) -> NodeEvidence? {
        if let known = readings[entryID] { return known }
        let built = build(entryID)
        readings[entryID] = built
        return built
    }

    /// An angle's ids are only unique inside that angle (`c1` means something different next door), so an
    /// angle reads its own evidence and nothing else. The answer's ids are rewritten run-unique (`a2c1`) and
    /// it reuses an angle's resolved citation verbatim, so it is backed by every angle's registry — that is
    /// where the document behind a reused citation was registered. What the run's sweep could not stand up
    /// rides along, so the answer's chips are drawn on the ladder its own validators left.
    private func build(_ entryID: String) -> NodeEvidence? {
        guard let entry = report.entries.first(where: { $0.id == entryID }),
              let transcriptPath = entry.transcriptPath else { return nil }
        let own = entry.evidence ?? EvidenceIndex()
        let merged = entry.isSynthesis == true
            ? report.entries.compactMap(\.evidence).reduce(own) { $0.merging($1) }
                .marking(unsupported: report.validation?.unsupportedCitationIDs ?? [])
            : own
        guard !merged.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: transcriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("evidence")
        return NodeEvidence(index: merged, directory: directory)
    }
}
