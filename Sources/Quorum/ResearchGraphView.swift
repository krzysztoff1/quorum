import SwiftUI
import QuorumCore

/// The run, as the surface you work on rather than a picture beside it. Nodes carry their own results, a
/// pending question is approved on its card, and any node can be dug into. Edges are drawn in a `Canvas`
/// (immediate mode, cheap at every zoom); nodes are real views above it, because they hold buttons, live
/// text and heights that change when one is opened.
struct ResearchGraphView: View {
    let graph: ResearchGraph
    var live: (String) -> LiveSnapshot? = { _ in nil }
    var onApprove: (String) -> Void = { _ in }
    var onReject: (String) -> Void = { _ in }
    var onDig: (GraphNode) -> Void = { _ in }
    var onPrune: (String) -> Void = { _ in }
    var onRetry: (String) -> Void = { _ in }

    @State private var opened: String?
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var focused: String?
    @State private var zoom: CGFloat = 1
    @State private var placement = PlacedGraph(frames: [], bounds: .zero)

    private var layout: GraphLayout { GraphLayout.best(for: visible) }

    /// The skeleton first. A finished run holds twenty-odd findings, and putting them all on one rank is a
    /// canvas thousands of points wide that answers nothing — a node hands over its claims when asked.
    private var visible: ResearchGraph {
        graph.skeleton(expanding: expanded).hiding(under: collapsed)
    }

    /// The path from the root to whatever is focused. Everything off it dims, so a deep branch can be read
    /// without losing where it hangs from.
    private var lit: Set<String> {
        guard let focused else { return [] }
        return Set(graph.ancestry(of: focused))
    }

    var body: some View {
        HStack(spacing: 0) {
            canvas
            if let opened, let node = graph.node(opened), node.deservesRail {
                Divider()
                ReadingRail(node: node, live: live(node.id), graph: graph) { self.opened = nil }
                    .frame(width: 420)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: opened)
        .onAppear(perform: reflow)
        .onChange(of: graph) { reflow() }
        .onChange(of: opened) { reflow() }
        .onChange(of: collapsed) { reflow() }
        .onChange(of: expanded) { reflow() }
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(edges: context) }
                    .frame(width: placement.bounds.width, height: placement.bounds.height)
                ForEach(visible.nodes) { node in
                    if let frame = placement.frame(node.id) {
                        nodeView(node)
                            .frame(width: frame.rect.width, height: frame.rect.height, alignment: .topLeading)
                            .offset(x: frame.rect.minX - placement.bounds.minX,
                                    y: frame.rect.minY - placement.bounds.minY)
                            .opacity(dimmed(node) ? 0.32 : 1)
                    }
                }
            }
            .frame(width: placement.bounds.width, height: placement.bounds.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: placement.bounds.width * zoom, height: placement.bounds.height * zoom,
                   alignment: .topLeading)
            .padding(24)
            .animation(.easeOut(duration: 0.3), value: placement)
        }
        .background(.background)
        .overlay(alignment: .top) { unvalidatedBanner }
        .overlay(alignment: .bottomTrailing) { controls }
    }

    private func draw(edges context: GraphicsContext) {
        for edge in visible.edges {
            guard let route = placement.route(edge) else { continue }
            var path = Path()
            path.move(to: shifted(route.points[0]))
            for point in route.points.dropFirst() { path.addLine(to: shifted(point)) }
            let strong = lit.contains(edge.from) && lit.contains(edge.to)
            context.stroke(path, with: .color(edge.tint.opacity(lit.isEmpty || strong ? 0.55 : 0.14)),
                           style: StrokeStyle(lineWidth: edge.kind == .corroborates ? 1 : 1.5,
                                              lineCap: .round, lineJoin: .round,
                                              dash: edge.kind == .corroborates ? [3, 4] : []))
            if let anchor = route.labelAnchor, let label = edge.label {
                let text = Text(label).font(.caption2).foregroundStyle(.secondary)
                context.draw(text, at: shifted(anchor), anchor: .center)
            }
        }
    }

    private func shifted(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - placement.bounds.minX, y: point.y - placement.bounds.minY)
    }

    private func dimmed(_ node: GraphNode) -> Bool {
        !lit.isEmpty && !lit.contains(node.id)
    }

    @ViewBuilder private func nodeView(_ node: GraphNode) -> some View {
        GraphNodeCard(
            node: node,
            detail: detail(for: node),
            live: live(node.id),
            childCount: graph.children(of: node.id).count,
            detailCount: graph.detailCount(under: node.id),
            isCollapsed: collapsed.contains(node.id),
            isExpanded: expanded.contains(node.id),
            onOpen: { opened = opened == node.id ? nil : node.id },
            onFocus: { focused = focused == node.id ? nil : node.id },
            onToggleDetail: { toggleDetail(node.id) },
            onToggleCollapse: { toggleCollapse(node.id) },
            onApprove: { onApprove(node.id) },
            onReject: { onReject(node.id) },
            onDig: { onDig(node) },
            onPrune: { onPrune(node.id) },
            onRetry: { onRetry(node.id) })
    }

    private func detail(for node: GraphNode) -> GraphNodeDetail {
        if collapsed.contains(node.id) || zoom < 0.55 { return .chip }
        return opened == node.id ? .open : .card
    }

    private func toggleCollapse(_ id: String) {
        withAnimation(.easeOut(duration: 0.25)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    private func toggleDetail(_ id: String) {
        withAnimation(.easeOut(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func reflow() {
        let current = visible
        let sizes = Dictionary(uniqueKeysWithValues: current.nodes.map {
            ($0.id, GraphNodeCard.size(for: $0, detail: detail(for: $0)))
        })
        placement = layout.place(current, sizes: sizes, previous: placement)
    }

    /// A run with no search key captured nothing, so nothing on this canvas was checked against a source.
    /// It says so on the canvas itself rather than leaving the absence of a chip to carry the message.
    @ViewBuilder private var unvalidatedBanner: some View {
        if !graph.isValidated {
            Label("Unvalidated — no evidence was captured for this run",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                .help("Its sources were read through built-in web search, which keeps no snapshot, so no quote in this run has been checked against one.")
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if focused != nil {
                Button("Clear focus") { withAnimation { focused = nil } }
                    .buttonStyle(.borderless).font(.caption)
            }
            if !collapsed.isEmpty {
                Button("Expand all") { withAnimation { collapsed.removeAll() } }
                    .buttonStyle(.borderless).font(.caption)
            }
            Button { zoom = max(0.4, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom = min(1.6, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
            Text(layout.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }
}

enum GraphNodeDetail { case chip, card, open }

/// Digging down: a question the user raises from a node, seeded with where they raised it. It runs under
/// the same gates as anything the model asks for — depth, dedup, the count cap — and needs no approval.
struct DigDownSheet: View {
    let node: GraphNode
    var onDig: (String) -> Void
    var onCancel: () -> Void

    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research further from here").font(.headline)
            Text(node.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("What should this branch find out?", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Text("Runs as a child of this node, on the run's remaining budget.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Research") { onDig(question) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// One node at whatever fidelity the canvas is asking for. Sizes are declared rather than measured so the
/// layout stays a pure function of the graph — the same input always draws the same picture.
struct GraphNodeCard: View {
    let node: GraphNode
    let detail: GraphNodeDetail
    var live: LiveSnapshot?
    var childCount = 0
    var detailCount = 0
    var isCollapsed = false
    var isExpanded = false
    var onOpen: () -> Void = {}
    var onFocus: () -> Void = {}
    var onToggleDetail: () -> Void = {}
    var onToggleCollapse: () -> Void = {}
    var onApprove: () -> Void = {}
    var onReject: () -> Void = {}
    var onDig: () -> Void = {}
    var onPrune: () -> Void = {}
    var onRetry: () -> Void = {}

    static let chipSize = CGSize(width: 132, height: 40)
    static let cardWidth: CGFloat = 240
    static let openSize = CGSize(width: 360, height: 300)

    /// Detail cards are narrower than the structure they hang off: ten findings at full width is a rank
    /// three thousand points across, which is not a diagram anyone reads.
    static let detailWidth: CGFloat = 168

    static func size(for node: GraphNode, detail: GraphNodeDetail) -> CGSize {
        switch detail {
        case .chip: return chipSize
        case .open: return openSize
        case .card: return CGSize(width: node.kind.isDetail ? detailWidth : cardWidth,
                                  height: cardHeight(for: node))
        }
    }

    private static func cardHeight(for node: GraphNode) -> CGFloat {
        switch node.kind {
        case .source, .finding, .gap:  return 76
        case .question where node.isPending:  return 150
        case .question where node.isPlanning: return 138
        case .question:                return 92
        default:                       return 108
        }
    }

    var body: some View {
        Group {
            switch detail {
            case .chip: chip
            case .card: card
            case .open: opened
            }
        }
        .contextMenu { menu }
        .onTapGesture(count: 2) { onFocus() }
        .onTapGesture { onOpen() }
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind.icon).font(.caption2)
            Text(node.title).font(.caption2).lineLimit(1)
            if childCount > 0 && isCollapsed {
                Text("\(childCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(node.kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(node.title)
                .font(.caption.weight(.semibold))
                .lineLimit(node.kind == .question ? 3 : 2)
                .multilineTextAlignment(.leading)
            if node.isPending { pendingBody }
            else if node.isPlanning { planningBody }
            else { resultBody }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(node.kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    private var header: some View {
        HStack(spacing: 5) {
            if node.isPlanning {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
                Image(systemName: node.kind.icon).font(.caption2)
            }
            Text(node.kind.label.uppercased()).font(.system(size: 9, weight: .bold))
            Spacer()
            if let badge = node.stateBadge {
                Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(node.strokeTint)
            }
            if node.costUSD > 0 {
                Text(node.costUSD.moneyLabel).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(node.kind.tint)
    }

    @ViewBuilder private var pendingBody: some View {
        if let why = node.reason {
            Text("why: \(why)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 6) {
            Button("Approve", action: onApprove).buttonStyle(.borderedProminent).controlSize(.mini)
            Button("Reject", action: onReject).buttonStyle(.bordered).controlSize(.mini)
            Spacer()
            if let estimate = node.estimatedCostUSD {
                Text("~\(estimate.moneyLabel)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    /// The decomposition, streaming on the node it is decomposing. The planner's reasoning is the first
    /// thing the run produces, so the canvas should be where it lands rather than a screen you leave.
    @ViewBuilder private var planningBody: some View {
        if let subtitle = node.subtitle {
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if let stream = live, !stream.thinkingTail.isEmpty {
            Text(stream.thinkingTail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .animation(.easeOut(duration: 0.2), value: stream.thinkingTail)
        }
    }

    @ViewBuilder private var resultBody: some View {
        if let subtitle = node.subtitle, !subtitle.isEmpty {
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        } else if let streaming = live?.output, !streaming.isEmpty {
            Text(streaming.suffix(120)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        } else if let reason = node.reason {
            Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        if detailCount > 0 {
            Button(action: onToggleDetail) {
                Label("\(detailCount) \(node.detailWord)", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(node.kind.tint)
        }
    }

    private var opened: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(node.title).font(.subheadline.weight(.semibold))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let subtitle = node.subtitle { Text(subtitle).font(.caption) }
                    if let streaming = live?.output, !streaming.isEmpty {
                        Text(streaming).font(.caption).foregroundStyle(.secondary)
                    }
                    if let reason = node.reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(node.kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(node.strokeTint, lineWidth: 1.5))
    }

    @ViewBuilder private var menu: some View {
        Button("Research further from here", systemImage: "arrow.triangle.branch", action: onDig)
        if childCount > 0 {
            Button(isCollapsed ? "Expand" : "Collapse", systemImage: "chevron.down.square",
                   action: onToggleCollapse)
        }
        Button("Focus this path", systemImage: "scope", action: onFocus)
        if node.isSpent {
            Divider()
            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
            Button("Prune this branch", systemImage: "scissors", role: .destructive, action: onPrune)
        }
    }
}

/// Long-form reading, beside the canvas rather than inside a node. A synthesis in a pannable box is worse
/// than a synthesis in a column; the graph stays the place you are while text gets to be text.
struct ReadingRail: View {
    let node: GraphNode
    var live: LiveSnapshot?
    let graph: ResearchGraph
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(node.kind.label, systemImage: node.kind.icon).font(.caption.weight(.semibold))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(node.title).font(.headline)
                    if let document = node.document {
                        Link(document.url, destination: URL(string: document.url) ?? URL(fileURLWithPath: "/"))
                            .font(.caption)
                    }
                    if let body = live?.output, !body.isEmpty {
                        MarkdownView(markdown: body)
                    } else if let subtitle = node.subtitle {
                        Text(subtitle).font(.body)
                    }
                    if !cited.isEmpty {
                        Divider()
                        Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(cited) { source in
                            Label(source.title, systemImage: "doc.text").font(.caption).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(.background)
    }

    private var cited: [GraphNode] {
        graph.children(of: node.id).filter { $0.kind == .source }
    }
}

private extension GraphNodeKind {
    var icon: String {
        switch self {
        case .question:     return "questionmark.circle"
        case .inquiry:      return "magnifyingglass"
        case .source:       return "doc.text"
        case .finding:      return "checkmark.seal"
        case .conflict:     return "exclamationmark.triangle"
        case .gap:          return "circle.dashed"
        case .synthesis:    return "square.stack.3d.up"
        case .verification: return "checkmark.shield"
        case .verdict:      return "gavel"
        }
    }

    var label: String {
        switch self {
        case .question:     return "Question"
        case .inquiry:      return "Angle"
        case .source:       return "Source"
        case .finding:      return "Finding"
        case .conflict:     return "Conflict"
        case .gap:          return "Gap"
        case .synthesis:    return "Synthesis"
        case .verification: return "Verified"
        case .verdict:      return "Verdict"
        }
    }

    var tint: Color {
        switch self {
        case .question:     return .accentColor
        case .inquiry:      return .blue
        case .source:       return .teal
        case .finding:      return .green
        case .conflict:     return .orange
        case .gap:          return .purple
        case .synthesis:    return .accentColor
        case .verification: return .green
        case .verdict:      return .pink
        }
    }
}

private extension GraphNode {
    var strokeTint: Color {
        switch state {
        case .asked(.planning):  return .accentColor
        case .asked(.pending):   return .orange
        case .asked(.rejected):  return .secondary
        case .asked(.expired):   return .secondary
        case .worked(.error):    return .red
        case .worked(.running):  return .blue
        case .judged(0):         return .green
        default:                 return kind.tint.opacity(0.45)
        }
    }

    /// A pending question is drawn dashed because nothing has been spent on it yet — the outline is the
    /// difference between a request and a fact.
    var strokeStyle: StrokeStyle {
        isPending ? StrokeStyle(lineWidth: 1.5, dash: [5, 4]) : StrokeStyle(lineWidth: 1)
    }

    var isPlanning: Bool { state == .asked(.planning) }

    var detailWord: String { kind == .synthesis ? "open points" : "findings" }

    var stateBadge: String? {
        switch state {
        case .asked(.planning):  return "PLANNING"
        case .asked(.pending):   return "PENDING"
        case .asked(.rejected):  return "REFUSED"
        case .asked(.expired):   return "EXPIRED"
        case .worked(.running):  return "RUNNING"
        case .worked(.error):    return "FAILED"
        case .judged(0):         return "HELD"
        case let .judged(count): return "\(count) OBJECTION\(count == 1 ? "" : "S")"
        default:                 return nil
        }
    }

    var deservesRail: Bool {
        kind == .synthesis || kind == .inquiry || kind == .source
    }
}

private extension GraphEdge {
    var tint: Color {
        switch kind {
        case .spawned:      return .orange
        case .corroborates: return .teal
        case .contradicts:  return .orange
        case .cites:        return .teal
        case .judges:       return .pink
        default:            return .secondary
        }
    }
}

private extension Decimal {
    var moneyLabel: String {
        let value = NSDecimalNumber(decimal: self).doubleValue
        return value < 1 ? String(format: "$%.2f", value) : String(format: "$%.1f", value)
    }
}
