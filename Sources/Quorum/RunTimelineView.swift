import SwiftUI
import QuorumCore

/// The run as a profiler trace: one lane per agent on a shared clock, ticks where it searched and
/// fetched, a band where it wrote, and vertical ties wherever two blind angles independently reached
/// the same document. Reads duration, parallelism, stalls and convergence off one picture — the things
/// a static node graph cannot show.
struct RunTimelineTrace: View {
    let run: LiveRun
    let onSelect: (TimelineLane) -> Void

    private let rowHeight: CGFloat = 30
    private let labelWidth: CGFloat = 186
    private let statsWidth: CGFloat = 164
    @State private var hovered: HoveredEvent?

    private var isLive: Bool { run.fanOut.phase != .done }

    var body: some View {
        Group {
            if isLive {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in trace(run.timeline(now: ctx.date)) }
            } else {
                trace(run.timeline(now: run.finishedAt ?? Date()))
            }
        }
    }

    private func trace(_ timeline: RunTimeline) -> some View {
        VStack(spacing: 0) {
            summary(timeline)
            Divider()
            axis(timeline)
            Divider()
            ScrollView(.vertical) { lanes(timeline) }
            Divider()
            footer(timeline)
        }
    }

    // MARK: - Header

    private func summary(_ timeline: RunTimeline) -> some View {
        let angles = timeline.lanes.filter { $0.role == .angle }
        let sources = angles.reduce(0) { $0 + $1.sourceCount }
        let shared = timeline.ties.count
        return HStack(spacing: 14) {
            stat("\(angles.count)", "angles")
            stat("\(sources)", "sources read")
            stat("\(shared)", "reached by 2+", tint: shared > 0 ? Color.accentColor : .secondary)
            stat(Reporter.fmtDuration(timeline.span), "elapsed")
            Spacer()
            Text(Reporter.money(angles.reduce(Decimal(0)) { $0 + $1.costUSD }))
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func axis(_ timeline: RunTimeline) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelWidth)
            GeometryReader { geo in
                ForEach(timeline.axis) { tick in
                    Text(tick.label)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: geo.size.width * timeline.fraction(of: tick.at), y: 9)
                }
            }
            .frame(height: 18)
            Color.clear.frame(width: statsWidth)
        }
        .padding(.horizontal, 14).padding(.top, 4)
    }

    // MARK: - Lanes

    private func lanes(_ timeline: RunTimeline) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(timeline.lanes) { lane in
                    laneLabel(lane, timeline: timeline).frame(height: rowHeight)
                }
            }
            .frame(width: labelWidth, alignment: .leading)

            track(timeline)

            VStack(spacing: 0) {
                ForEach(timeline.lanes) { lane in
                    laneStats(lane, timeline: timeline).frame(height: rowHeight)
                }
            }
            .frame(width: statsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func laneLabel(_ lane: TimelineLane, timeline: RunTimeline) -> some View {
        let stalled = timeline.stall(of: lane)
        return Button { onSelect(lane) } label: {
            HStack(spacing: 6) {
                laneIcon(lane)
                Text(lane.title).font(.caption.weight(lane.role == .angle ? .regular : .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(stalled == nil ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(lane.title)
    }

    private func laneIcon(_ lane: TimelineLane) -> some View {
        NodeStyleIcon(style: NodeStyle.lane(role: lane.role, status: lane.status))
            .font(.caption2)
            .scaleEffect(lane.status == .running ? 0.7 : 1)
            .frame(width: 12)
    }

    private func laneStats(_ lane: TimelineLane, timeline: RunTimeline) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let stalled = timeline.stall(of: lane) {
                Label("quiet \(Reporter.fmtDuration(stalled))", systemImage: "zzz")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
            } else {
                if lane.sourceCount > 0 {
                    Text("\(lane.sourceCount) src").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if lane.costUSD > 0 {
                    Text(Reporter.money(lane.costUSD)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if lane.status != .queued {
                    Text(Reporter.fmtDuration(timeline.duration(of: lane)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - The track

    private func track(_ timeline: RunTimeline) -> some View {
        let height = rowHeight * CGFloat(max(timeline.lanes.count, 1))
        return GeometryReader { geo in
            Canvas { ctx, size in draw(timeline, in: ctx, size: size) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = nearest(to: point, in: geo.size, timeline: timeline)
                    case .ended: hovered = nil
                    }
                }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    private func rowCenter(_ index: Int) -> CGFloat { rowHeight * (CGFloat(index) + 0.5) }

    private func draw(_ timeline: RunTimeline, in ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        func x(_ date: Date) -> CGFloat { w * timeline.fraction(of: date) }

        for tick in timeline.axis {
            let gx = x(tick.at)
            ctx.stroke(Path { $0.move(to: CGPoint(x: gx, y: 0)); $0.addLine(to: CGPoint(x: gx, y: size.height)) },
                       with: .color(.secondary.opacity(0.10)), lineWidth: 1)
        }

        for (i, lane) in timeline.lanes.enumerated() {
            let y = rowCenter(i)
            let laneStart = lane.events.first?.at ?? lane.writingStartedAt ?? timeline.start
            let laneEnd = lane.finishedAt ?? timeline.now
            let stalled = timeline.stall(of: lane) != nil

            if lane.status != .queued {
                ctx.fill(Path(roundedRect: CGRect(x: x(laneStart), y: y - 1.5,
                                                  width: max(2, x(laneEnd) - x(laneStart)), height: 3),
                              cornerRadius: 1.5),
                         with: .color(.secondary.opacity(stalled ? 0.12 : 0.22)))
            }

            if let band = timeline.writingBand(of: lane) {
                let left = w * band.lowerBound
                ctx.fill(Path(roundedRect: CGRect(x: left, y: y - 4.5,
                                                  width: max(3, w * band.upperBound - left), height: 9),
                              cornerRadius: 3),
                         with: .color(.accentColor.opacity(lane.status == .running ? 0.45 : 0.3)))
            }

            if stalled, let last = lane.lastActivity {
                var dash = Path()
                dash.move(to: CGPoint(x: x(last), y: y))
                dash.addLine(to: CGPoint(x: x(timeline.now), y: y))
                ctx.stroke(dash, with: .color(.orange.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [2, 4]))
            }

            for event in lane.events { drawMark(event, at: CGPoint(x: x(event.at), y: y), in: ctx) }

            if lane.status == .complete, let end = lane.finishedAt {
                ctx.fill(Path(ellipseIn: CGRect(x: x(end) - 3.5, y: y - 3.5, width: 7, height: 7)),
                         with: .color(.green))
            }
        }

        drawTies(timeline, in: ctx, x: x)

        if isLive, timeline.span > 0 {
            let px = x(timeline.now)
            ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                       with: .color(.accentColor.opacity(0.35)), lineWidth: 1)
        }

        if let hovered {
            let hx = x(hovered.event.at), hy = rowCenter(hovered.laneIndex)
            ctx.stroke(Path(ellipseIn: CGRect(x: hx - 6, y: hy - 6, width: 12, height: 12)),
                       with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    private func drawMark(_ event: TimelineEvent, at point: CGPoint, in ctx: GraphicsContext) {
        switch event.mark {
        case .search:
            ctx.stroke(Path { $0.move(to: CGPoint(x: point.x, y: point.y - 5))
                              $0.addLine(to: CGPoint(x: point.x, y: point.y + 5)) },
                       with: .color(.secondary.opacity(0.65)), lineWidth: 1.5)
        case .fetch:
            ctx.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                     with: .color(.accentColor.opacity(0.85)))
        case .read:
            ctx.fill(Path(roundedRect: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5),
                          cornerRadius: 1),
                     with: .color(.secondary.opacity(0.8)))
        }
    }

    /// The convergence lines: where two blind angles landed on the same document, join their lanes at
    /// the moment the second one got there.
    private func drawTies(_ timeline: RunTimeline, in ctx: GraphicsContext, x: (Date) -> CGFloat) {
        let row = Dictionary(uniqueKeysWithValues: timeline.lanes.enumerated().map { ($0.element.id, $0.offset) })
        for tie in timeline.ties {
            let rows = tie.hits.compactMap { row[$0.laneID] }
            guard let top = rows.min(), let bottom = rows.max(), top != bottom else { continue }
            let tx = x(tie.convergedAt)
            let highlighted = hovered?.tieKeys.contains(tie.key) == true
            ctx.stroke(Path { $0.move(to: CGPoint(x: tx, y: rowCenter(top)))
                              $0.addLine(to: CGPoint(x: tx, y: rowCenter(bottom))) },
                       with: .color(.accentColor.opacity(highlighted ? 0.9 : 0.28)),
                       style: StrokeStyle(lineWidth: highlighted ? 1.8 : 1))
            for hit in tie.hits {
                guard let r = row[hit.laneID] else { continue }
                let hx = x(hit.at), hy = rowCenter(r)
                ctx.stroke(Path(ellipseIn: CGRect(x: hx - 4, y: hy - 4, width: 8, height: 8)),
                           with: .color(.accentColor.opacity(highlighted ? 0.9 : 0.35)), lineWidth: 1)
            }
        }
    }

    // MARK: - Hover readout

    private struct HoveredEvent {
        let laneIndex: Int
        let laneTitle: String
        let event: TimelineEvent
        let tieKeys: Set<String>
        let sharedWith: [String]
    }

    private func nearest(to point: CGPoint, in size: CGSize, timeline: RunTimeline) -> HoveredEvent? {
        let index = Int(point.y / rowHeight)
        guard timeline.lanes.indices.contains(index) else { return nil }
        let lane = timeline.lanes[index]
        let closest = lane.events.min {
            abs(size.width * timeline.fraction(of: $0.at) - point.x)
                < abs(size.width * timeline.fraction(of: $1.at) - point.x)
        }
        guard let closest,
              abs(size.width * timeline.fraction(of: closest.at) - point.x) < 8 else { return nil }
        let tie = closest.sourceKey.flatMap { key in timeline.ties.first { $0.key == key } }
        let titles = Dictionary(uniqueKeysWithValues: timeline.lanes.map { ($0.id, $0.title) })
        return HoveredEvent(
            laneIndex: index, laneTitle: lane.title, event: closest,
            tieKeys: tie.map { [$0.key] } ?? [],
            sharedWith: (tie?.hits.map(\.laneID) ?? []).filter { $0 != lane.id }.compactMap { titles[$0] })
    }

    // MARK: - Footer

    @ViewBuilder private func footer(_ timeline: RunTimeline) -> some View {
        if let hovered {
            HStack(spacing: 8) {
                Image(systemName: hovered.event.mark == .search ? "magnifyingglass"
                      : (hovered.event.mark == .read ? "doc.text" : "arrow.down.circle"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(hovered.event.label).font(.caption).lineLimit(1).truncationMode(.middle)
                if !hovered.sharedWith.isEmpty {
                    Text("also reached by \(hovered.sharedWith.joined(separator: ", "))")
                        .font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Spacer()
                Text(RunTimeline.clockLabel(hovered.event.at.timeIntervalSince(timeline.start)))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        } else {
            HStack(spacing: 14) {
                legend("searched", shape: .search)
                legend("fetched", shape: .fetch)
                legend("read locally", shape: .read)
                legend("writing", shape: nil)
                legend("same source, two angles", shape: nil, tie: true)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    private func legend(_ text: String, shape: TimelineMark?, tie: Bool = false) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, size in
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                if tie {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mid.x, y: 1))
                                      $0.addLine(to: CGPoint(x: mid.x, y: size.height - 1)) },
                               with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
                } else if let shape {
                    drawMark(TimelineEvent(at: .now, mark: shape, label: ""), at: mid, in: ctx)
                } else {
                    ctx.fill(Path(roundedRect: CGRect(x: 1, y: mid.y - 4, width: size.width - 2, height: 8),
                                  cornerRadius: 3),
                             with: .color(.accentColor.opacity(0.35)))
                }
            }
            .frame(width: 14, height: 12)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Live state → lanes

extension LiveRun {

    /// The lanes of this run's trace, in the order they opened: every round's angles, then the synthesis
    /// that closed the fan, then the citation-grounding pass.
    func timeline(now: Date) -> RunTimeline {
        // Round-major, planner order within a round — `sorted` isn't stable, so the original index breaks
        // ties rather than the angle id ("a10" would sort before "a2").
        var lanes = fanOut.angles.enumerated()
            .sorted { ($0.element.round, $0.offset) < ($1.element.round, $1.offset) }
            .map { _, angle -> TimelineLane in
            let snap = liveByAngle[angle.id]
            let multiRound = fanOut.roundAngleCounts.count > 1
            return TimelineLane(
                id: angle.id,
                title: (multiRound ? "R\(angle.round) · " : "") + (angle.angle.title.isEmpty ? "Angle" : angle.angle.title),
                role: .angle, round: angle.round, status: angle.status,
                events: snap.map(Self.events) ?? [],
                writingStartedAt: snap?.writingStartedAt,
                finishedAt: angleFinishedAt[angle.id],
                costUSD: snap?.costUSD ?? 0)
        }

        let phase = fanOut.phase
        lanes.append(TimelineLane(
            id: "synthesis", title: "Synthesis", role: .synthesis, round: fanOut.round,
            status: phase == .synthesizing ? .running : (phase.checksTheAnswer || phase == .done ? .complete : .queued),
            events: Self.events(synthesisLive),
            writingStartedAt: synthesisLive.writingStartedAt ?? phaseStartedAt[.synthesizing],
            finishedAt: phaseStartedAt[.verifying] ?? (phase == .done ? finishedAt : nil),
            costUSD: synthesisLive.costUSD))

        lanes.append(TimelineLane(
            id: "verify", title: "Verify sources", role: .verify, round: fanOut.round,
            status: phase.checksTheAnswer ? .running : (phase == .done ? .complete : .queued),
            events: Self.events(verifyLive),
            writingStartedAt: verifyLive.writingStartedAt ?? phaseStartedAt[.verifying],
            finishedAt: phase == .done ? finishedAt : nil,
            costUSD: verifyLive.costUSD))

        return RunTimeline(lanes: lanes, start: researchStartedAt, now: now)
    }

    private static func events(_ snap: LiveSnapshot) -> [TimelineEvent] {
        snap.sources.map { TimelineEvent(at: $0.at, mark: TimelineMark(toolName: $0.kind), label: $0.value) }
    }
}
