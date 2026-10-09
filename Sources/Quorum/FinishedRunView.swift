import SwiftUI
import QuorumCore

/// A finished run, opened on the surface it ran on. The same `ResearchGraphView` the run was watched on,
/// fed by `ResearchGraph.from(report:)` instead of by the stream — so a legacy fan, a graph run and a
/// validated dive are one component reading one structure, with the run's numbers on a strip above it. The
/// canvas opens focused on the answer the dive currently holds, rail already reading it: the first thing on
/// screen is the answer, cited and badged, beside the shape that produced it.
struct FinishedRunView: View {
    let report: RunReport
    let projectPath: String
    /// The export the run wrote, opened in the editor the notes browser already uses — the graph leads,
    /// the note stays one click away from the node that wrote it (PRD 09 R4).
    var onOpenNote: (String) -> Void = { _ in }

    private let graph: ResearchGraph
    private let header: RunHeader
    /// Read once per run, not once per redraw: the rail opens on one node, and the merged registry behind
    /// the answer has no business being reassembled every time a card changes size (PRD 09 R6).
    @State private var evidence: ReportEvidence

    init(report: RunReport, projectPath: String, onOpenNote: @escaping (String) -> Void = { _ in }) {
        self.report = report
        self.projectPath = projectPath
        self.onOpenNote = onOpenNote
        graph = ResearchGraph.from(report: report)
        header = RunHeader(report: report)
        _evidence = State(initialValue: ReportEvidence(report: report))
    }

    var body: some View {
        VStack(spacing: 0) {
            RunHeaderStrip(header: header, answer: answer)
            Divider()
            ResearchGraphView(graph: graph,
                              showsUnvalidatedBanner: false,
                              reading: { reading($0) },
                              onOpenNote: onOpenNote,
                              reveal: graph.answer?.id)
        }
    }

    private var answerEntry: RunReport.TopicEntry? {
        report.entries.last { $0.isSynthesis == true }
    }

    /// The note and chat for the answer the dive currently holds. The graph is what the run is read in; this
    /// is the way through to the portable export and the conversation seeded from it.
    private var answer: TopicTarget? {
        answerEntry.map { topic($0) }
    }

    private func topic(_ entry: RunReport.TopicEntry) -> TopicTarget {
        TopicTarget.from(entry, report: report, projectPath: projectPath,
                         evidence: evidence.reading(for: entry.id))
    }

    /// A finished node read the way a live one is: the note it wrote, with its citations resolving against
    /// the evidence the run kept. The answer carries two more readings — the audit of how it was reached,
    /// and what the run's own validators made of it — because those are things about the answer, and the
    /// answer is where they belong (PRD 09 R2).
    private func reading(_ node: GraphNode) -> NodeReading {
        guard let entry = report.entries.first(where: { $0.id == node.id }) else { return NodeReading() }
        let isAnswer = node.id == graph.answer?.id
        let target = topic(entry)
        return NodeReading(notePath: entry.notePath,
                           evidence: evidence.reading(for: entry.id),
                           topic: target,
                           audit: isAnswer ? target : nil,
                           validation: isAnswer ? report.validation : nil)
    }
}

/// What the digest list used to say, over the canvas rather than instead of it. Every value comes from
/// `RunHeader`, so the strip decides nothing about the run — it only draws it.
struct RunHeaderStrip: View {
    let header: RunHeader
    var answer: TopicTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let status = header.status { StatusBadge(status: status) }
                if header.isReconciled {
                    Label("Reconciled", systemImage: "arrow.triangle.merge")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Text(header.question).font(.headline).lineLimit(2)
                Spacer(minLength: 12)
                if let answer {
                    NavigationLink(value: answer) { Label("Note & chat", systemImage: "doc.text") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !header.headline.isEmpty {
                Text(header.headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            facts
            if let notice = header.unvalidatedNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("Its sources were read through built-in web search, which keeps no snapshot, so no quote in this run has been checked against one.")
            }
            if let notice = header.pipelineNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("This run never reached the engine, so no validator read its answer and nothing objected to it — an unjudged answer, not one that held.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        HStack(spacing: 14) {
            if !header.confidenceSummary.isEmpty {
                Label(header.confidenceSummary, systemImage: "checkmark.shield")
            }
            if header.conflicts > 0 {
                Label("\(header.conflicts) conflict\(header.conflicts == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if header.gaps > 0 {
                Label("\(header.gaps) gap\(header.gaps == 1 ? "" : "s")", systemImage: "questionmark.diamond.fill")
                    .foregroundStyle(.orange)
            }
            if header.outstandingObjections > 0 {
                Label("\(header.outstandingObjections) objection\(header.outstandingObjections == 1 ? "" : "s") standing",
                      systemImage: NodeStyle.objection(severity: "blocking").icon)
                    .foregroundStyle(NodeStyle.objection(severity: "blocking").color)
            }
            Label("\(header.sourcesConsulted) source\(header.sourcesConsulted == 1 ? "" : "s")", systemImage: "link")
            Label(header.roundsLabel, systemImage: "point.3.connected.trianglepath.dotted")
            Label(Reporter.fmtDuration(header.durationSeconds), systemImage: "clock")
            Label(Reporter.money(header.costUSD) + " / " + Reporter.money(header.capUSD),
                  systemImage: header.stayedUnderCap ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(header.stayedUnderCap ? .green : .orange)
            if let profile = header.profile, profile != .subscription {
                Label(profile.displayName, systemImage: "dial.medium")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// What the run's own validators made of its answer, beside the answer. A verdict never edited the text, so
/// this is where the argument lives: which task judged which round, what each filed, what the loop settled,
/// and — the part nothing is allowed to hide — what it never did (PRD 09 R2, R3).
struct ValidationTab: View {
    let validation: RunValidation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                verdict
                ledger
                if !validation.objectionsOutstanding.isEmpty { outstanding }
                rounds
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var verdict: some View {
        let style = NodeStyle.state(of: GraphNode(id: "", kind: .verdict, title: "",
                                                  state: .judged(objections: validation.objectionsOutstanding.count)))
        return VStack(alignment: .leading, spacing: 4) {
            Label(validation.holds ? "The answer held" : "The answer did not hold",
                  systemImage: style.icon)
                .font(.headline).foregroundStyle(style.color)
            Text(validation.status == "validated"
                    ? "Judged by agents that did not write it, over \(validation.rounds) round\(validation.rounds == 1 ? "" : "s") · \(Reporter.money(validation.spendUSD))"
                    : "Not fully validated — some of the loop could not run on this answer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ledger: some View {
        HStack(spacing: 16) {
            count("filed", validation.objectionsAdmitted, tint: .secondary)
            count("settled by research", validation.objectionsResolved, tint: .green)
            count("still standing", validation.objectionsOutstanding.count,
                  tint: validation.objectionsOutstanding.isEmpty ? .secondary : .orange)
            if !validation.unsupportedCitationIDs.isEmpty {
                count("quotes badged ⚠", validation.unsupportedCitationIDs.count, tint: .red)
            }
            Spacer(minLength: 0)
        }
    }

    private func count(_ label: String, _ value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.weight(.semibold)).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var outstanding: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Still standing against the answer", systemImage: "exclamationmark.octagon.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text("A validator never fixes the answer. These were filed and not settled — they ship with it.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(validation.objectionsOutstanding.enumerated()), id: \.offset) { _, objection in
                ObjectionRow(objection: objection)
            }
        }
    }

    private var rounds: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Round by round", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(validation.byRound) { round in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Round \(round.number)").font(.caption.weight(.bold))
                        Text(round.holds ? "held" : "objections filed")
                            .font(.caption2)
                            .foregroundStyle(round.holds ? .green : .orange)
                    }
                    ForEach(round.verdicts, id: \.id) { verdict in verdictRow(verdict) }
                }
            }
        }
    }

    private func verdictRow(_ verdict: RunValidation.Verdict) -> some View {
        let node = GraphNode(id: verdict.id, kind: .verdict, title: verdict.title,
                             state: .derived, lens: verdict.lens, objections: verdict.objections)
        let lens = NodeStyle.node(node)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(verdict.title, systemImage: lens.icon).font(.caption)
                Spacer(minLength: 4)
                Text(verdict.status).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(verdict.objections.enumerated()), id: \.offset) { _, objection in
                ObjectionRow(objection: objection)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(lens.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One objection as it was filed: which lens raised it, how hard it lands, and the one task that would
/// settle it — the same three things its node on the canvas carries.
struct ObjectionRow: View {
    let objection: RunStreamParser.ObjectionEvent

    var body: some View {
        let style = NodeStyle.objection(severity: objection.severity)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: style.icon).font(.caption2).foregroundStyle(style.color)
                Text(objection.lens.replacingOccurrences(of: "_", with: " ").uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Text(objection.severity.uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(style.color)
            }
            Text(objection.statement).font(.caption)
            Label(objection.followup, systemImage: "arrow.turn.down.right")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
