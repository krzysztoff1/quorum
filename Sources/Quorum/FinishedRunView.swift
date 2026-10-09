import SwiftUI
import QuorumCore

struct FinishedRunView: View {
    let run: StoredRun

    private let graph: ResearchGraph
    private let header: RunHeader

    init(run: StoredRun) {
        self.run = run
        graph = run.graph
        header = RunHeader(run: run)
    }

    var body: some View {
        VStack(spacing: 0) {
            RunHeaderStrip(header: header, answer: answer)
            Divider()
            ResearchGraphView(graph: graph,
                              showsUnvalidatedBanner: false,
                              reading: { reading($0) },
                              reveal: graph.answer?.id)
        }
    }

    private var answer: TopicTarget? {
        run.answerTask.map { TopicTarget.from($0, in: run) }
    }

    private func reading(_ node: GraphNode) -> NodeReading {
        guard let task = run.task(forNode: node.id) else {
            return NodeReading(evidence: run.evidence(forNode: node.id))
        }
        let isAnswer = task.id == run.answerTask?.id
        let target = TopicTarget.from(task, in: run)
        return NodeReading(writeup: run.writeup(forNode: node.id),
                           evidence: run.evidence(forNode: node.id),
                           topic: target,
                           audit: isAnswer ? target : nil,
                           validation: isAnswer ? run.validation : nil)
    }
}

struct RunHeaderStrip: View {
    let header: RunHeader
    var answer: TopicTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadge(status: header.status)
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
                    NavigationLink(value: answer) { Label("Answer & chat", systemImage: "doc.text") }
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
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: some View {
        HStack(spacing: 14) {
            Label("trust: \(header.trustLevel.rawValue)", systemImage: "checkmark.shield")
            if !header.claimsSummary.isEmpty {
                Label(header.claimsSummary, systemImage: "text.badge.checkmark")
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
            Label(header.sourcesLabel, systemImage: "link")
            Label(header.roundsLabel, systemImage: "point.3.connected.trianglepath.dotted")
            Label(Format.duration(header.durationSeconds), systemImage: "clock")
            Label(Format.money(header.costUSD) + (header.capUSD.map { " / " + Format.money($0) } ?? ""),
                  systemImage: header.stayedUnderCap ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(header.stayedUnderCap ? .green : .orange)
            if header.strippedMarkers > 0 {
                Label("\(header.strippedMarkers) dangling marker\(header.strippedMarkers == 1 ? "" : "s") stripped",
                      systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                    .help("A writer cited a quote it never declared; the engine removed the marker and flagged it.")
            }
            if !header.failedChecks.isEmpty {
                Label("\(header.failedChecks.count) integrity check\(header.failedChecks.count == 1 ? "" : "s") failed",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .help(header.failedChecks.map { "\($0.id): \($0.detail)" }.joined(separator: "\n"))
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
                    ? "Judged by agents that did not write it, over \(validation.rounds) round\(validation.rounds == 1 ? "" : "s") · \(Format.money(validation.spendUSD))"
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
