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
    /// Nil where digging is not on offer — a finished run's canvas draws no affordance it cannot honour.
    var onDig: ((GraphNode) -> Void)?
    var onPrune: (String) -> Void = { _ in }
    var onRetry: (String) -> Void = { _ in }
    var onRetitle: (String, String) -> Void = { _, _ in }
    var onRewrite: (String, String) -> Void = { _, _ in }
    var onRemove: (String) -> Void = { _ in }
    var onAddAngle: () -> Void = {}
    var onFork: (GraphNode) -> Void = { _ in }
    var onResearch: () -> Void = {}
    /// What the rail beside the canvas reads for a node — the same reader a finished run gets, fed live.
    var reading: (GraphNode) -> NodeReading = { _ in NodeReading() }
    var bulkApprovals: BulkApprovals?
    /// A node ⌘K asked for. The canvas lights its path and opens it, then tells the caller it has, so the
    /// same node can be asked for again.
    var reveal: String?
    var onRevealed: () -> Void = {}
    var planCeilingUSD: Decimal?

    /// One verdict over every offer standing at once. It only exists past the second offer: below that the
    /// cards themselves are less work than reading a bar about them.
    struct BulkApprovals {
        let count: Int
        let onApproveAll: () -> Void
        let onRejectAll: () -> Void
    }

    @State private var opened: String?
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var focused: String?
    @State private var zoom: CGFloat = 1
    @State private var placement = PlacedGraph(frames: [], bounds: .zero)
    /// The chip the reader picked, and so the source that opens beside the canvas. Cleared when the rail
    /// moves to another node: a quote is only a quote of the thing being read.
    @State private var citation: Citation?

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
                ReadingRail(node: node, live: live(node.id), graph: graph, reading: reading(node),
                            citation: $citation) { self.opened = nil }
                    .frame(width: 420)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                sourceInspector(for: node)
            }
        }
        .animation(.easeOut(duration: 0.28), value: opened)
        .animation(.easeOut(duration: 0.28), value: citation)
        .onAppear(perform: reflow)
        .onAppear(perform: revealRequested)
        .onChange(of: reveal) { revealRequested() }
        .onChange(of: graph) { reflow() }
        .onChange(of: opened) { citation = nil; reflow() }
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
        .overlay(alignment: .topTrailing) { bulkApprovalBar }
        .overlay(alignment: .bottom) { researchCTA }
        .overlay(alignment: .bottomTrailing) { controls }
    }

    /// The source behind the chip that was picked, opened beside the prose quoting it rather than in place
    /// of it — the point of a citation is reading both at once.
    @ViewBuilder private func sourceInspector(for node: GraphNode) -> some View {
        if let citation, let context = reading(node).evidence {
            Divider()
            CitedSourceInspector(citation: citation, document: context.index.document(for: citation),
                                 evidenceDir: context.directory, grounding: context.grounding) {
                self.citation = nil
            }
            .frame(width: 520)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// A node named from outside the canvas — ⌘K, so far. Opening it is what makes the jump land: a node
    /// lit in a corner of a graph five ranks wide is not an answer to "where is it".
    private func revealRequested() {
        guard let reveal, graph.node(reveal) != nil else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            collapsed.subtract(graph.ancestry(of: reveal))
            focused = reveal
            opened = graph.node(reveal)?.deservesRail == true ? reveal : nil
        }
        onRevealed()
    }

    /// Offers pile up while the wave carries on around them, and past the second one the answer is usually
    /// the same for all of them. The bar says how many there are and rules on the lot.
    @ViewBuilder private var bulkApprovalBar: some View {
        if let bulk = bulkApprovals {
            HStack(spacing: 8) {
                Label("\(bulk.count) questions raised", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                Button("Approve all", action: bulk.onApproveAll)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Reject all", action: bulk.onRejectAll)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
        }
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
            showsAddAngle: isPlanRoot(node),
            canDig: onDig != nil && graph.canDig(node.id),
            canPrune: graph.canPrune(node.id),
            canRetry: graph.canRetry(node.id),
            onOpen: { opened = opened == node.id ? nil : node.id },
            onFocus: { focused = focused == node.id ? nil : node.id },
            onToggleDetail: { toggleDetail(node.id) },
            onToggleCollapse: { toggleCollapse(node.id) },
            onApprove: { onApprove(node.id) },
            onReject: { onReject(node.id) },
            onDig: { onDig?(node) },
            onPrune: { onPrune(node.id) },
            onRetry: { onRetry(node.id) },
            onRetitle: { onRetitle(node.id, $0) },
            onRewrite: { onRewrite(node.id, $0) },
            onRemove: { onRemove(node.id) },
            onAddAngle: onAddAngle,
            onFork: { onFork(node) })
    }

    /// The question everything under review hangs from, which is where a new angle is added — a plan grows
    /// from the thing being asked, not from one of its answers.
    private func isPlanRoot(_ node: GraphNode) -> Bool {
        node.id == ResearchGraph.rootID && !graph.proposedAngles.isEmpty
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
            ($0.id, GraphNodeCard.size(for: $0, detail: detail(for: $0), isPlanRoot: isPlanRoot($0)))
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

    /// The one place a plan turns into spending. It floats over the cards it is about, so the decision and
    /// the thing being decided are never on two different screens.
    @ViewBuilder private var researchCTA: some View {
        let proposed = graph.proposedAngles
        if !proposed.isEmpty {
            VStack(spacing: 5) {
                Button(action: onResearch) {
                    Label("Research \(proposed.count) angle\(proposed.count == 1 ? "" : "s")",
                          systemImage: "play.fill")
                        .font(.headline).padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!graph.planIsRunnable)
                Text(ctaSubtitle)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 20)
        }
    }

    private var ctaSubtitle: String {
        guard graph.planIsRunnable else { return "every angle needs to say what it would research" }
        guard let ceiling = planCeilingUSD else { return "nothing is spent until you start" }
        return "up to \(ceiling.capLabel) · nothing is spent until you start"
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
    var showsAddAngle = false
    /// Steering is drawn only where it lands: a branch with nothing unspent under it cannot be pruned,
    /// and a topic that never stopped cannot be run again.
    var canDig = false
    var canPrune = false
    var canRetry = false
    var onOpen: () -> Void = {}
    var onFocus: () -> Void = {}
    var onToggleDetail: () -> Void = {}
    var onToggleCollapse: () -> Void = {}
    var onApprove: () -> Void = {}
    var onReject: () -> Void = {}
    var onDig: () -> Void = {}
    var onPrune: () -> Void = {}
    var onRetry: () -> Void = {}
    var onRetitle: (String) -> Void = { _ in }
    var onRewrite: (String) -> Void = { _ in }
    var onRemove: () -> Void = {}
    var onAddAngle: () -> Void = {}
    var onFork: () -> Void = {}

    @State private var isHovered = false

    static let chipSize = CGSize(width: 132, height: 40)
    static let cardWidth: CGFloat = 240
    static let openSize = CGSize(width: 360, height: 300)

    /// Detail cards are narrower than the structure they hang off: ten findings at full width is a rank
    /// three thousand points across, which is not a diagram anyone reads.
    static let detailWidth: CGFloat = 168

    /// A verdict's chip carries the lens and, when it filed something, the count — "coverage · 2
    /// objections" does not fit the width a one-word chip was sized for.
    static let verdictChipSize = CGSize(width: 176, height: 40)

    /// A proposed angle is two text fields rather than a sentence of output, so it is drawn wider and
    /// taller than the card it becomes once it runs.
    static let planCardSize = CGSize(width: 288, height: 178)
    static let addAngleRowHeight: CGFloat = 26

    static func size(for node: GraphNode, detail: GraphNodeDetail, isPlanRoot: Bool = false) -> CGSize {
        switch detail {
        case .chip: return node.kind == .verdict ? verdictChipSize : chipSize
        case .open: return openSize
        case .card:
            if node.isProposed { return planCardSize }
            return CGSize(width: node.kind.isDetail ? detailWidth : cardWidth,
                          height: cardHeight(for: node) + (isPlanRoot ? addAngleRowHeight : 0))
        }
    }

    private static func cardHeight(for node: GraphNode) -> CGFloat {
        switch node.kind {
        case .source, .finding, .gap:  return 76
        case .question where node.isPending:  return 150
        case .question where node.isPlanning: return 138
        case .question:                return 92
        case .verdict:                 return 84 + CGFloat(min(node.objections.count, 3)) * 34
        default:                       return 108
        }
    }

    /// A proposed angle is typed into, so it must not sit under a tap gesture that would steal the click
    /// away from its own fields.
    @ViewBuilder var body: some View {
        if node.isProposed {
            Group {
                if detail == .chip { chip } else { planEditor }
            }
            .contextMenu { menu }
        } else {
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
            .overlay(alignment: .topTrailing) { digButton }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
            }
        }
    }

    /// Researching further from a node is the human half of the loop, so it is on the node: hovering any of
    /// them offers it. The context menu keeps the same action for anyone who already learnt it there.
    @ViewBuilder private var digButton: some View {
        if canDig && isHovered {
            Button(action: onDig) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(node.tint.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(node.tint)
            .offset(x: 7, y: -7)
            .help("Research further from here")
            .transition(.opacity)
        }
    }

    /// The angle as the reader would file it: its own title, its own prompt, and a price it has not spent.
    private var planEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: node.style.icon).font(.caption2)
                Text("ANGLE").font(.system(size: 9, weight: .bold))
                Spacer()
                Button(action: onOpen) {
                    Image(systemName: detail == .open ? "arrow.down.right.and.arrow.up.left"
                                                      : "arrow.up.left.and.arrow.down.right")
                }
                .help(detail == .open ? "Show less of this angle" : "Write this angle in full")
                Button(action: onRemove) { Image(systemName: "trash") }
                    .help("Remove this angle")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10))
            .foregroundStyle(node.tint)
            TextField("Angle title", text: titleField)
                .textFieldStyle(.plain)
                .font(.caption.weight(.semibold))
            TextField("What should this angle investigate?", text: promptField, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .lineLimit(detail == .open ? 6...14 : 3...4)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            if let estimate = node.estimatedCostUSD {
                Text("up to \(estimate.moneyLabel)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(node.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    private var titleField: Binding<String> {
        Binding(get: { node.title }, set: onRetitle)
    }

    private var promptField: Binding<String> {
        Binding(get: { node.prompt ?? "" }, set: onRewrite)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: node.icon).font(.caption2)
            Text(node.chipTitle).font(.caption2).lineLimit(1)
            if childCount > 0 && isCollapsed {
                Text("\(childCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(node.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
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
            else if node.kind == .verdict { verdictBody }
            else { resultBody }
            if showsAddAngle {
                Button(action: onAddAngle) {
                    Label("Add an angle", systemImage: "plus.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(node.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    private var header: some View {
        HStack(spacing: 5) {
            if node.stateStyle.showsProgress {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
                Image(systemName: node.icon).font(.caption2)
            }
            Text(node.rowLabel.uppercased()).font(.system(size: 9, weight: .bold))
            Spacer()
            if let badge = node.stateBadge {
                Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(node.strokeTint)
            }
            if node.costUSD > 0 {
                Text(node.costUSD.moneyLabel).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(node.tint)
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

    /// What the task made of the answer, at card fidelity: the headline of each objection, because the
    /// count alone says an argument happened without saying what it was about.
    @ViewBuilder private var verdictBody: some View {
        if node.objections.isEmpty {
            Label(node.wasSkipped ? "not run — nothing was checked" : "nothing filed against the answer",
                  systemImage: node.stateStyle.icon)
                .font(.system(size: 10))
                .foregroundStyle(node.stateStyle.color)
        }
        ForEach(Array(node.objections.prefix(3).enumerated()), id: \.offset) { _, objection in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: objection.style.icon)
                    .font(.system(size: 8))
                    .foregroundStyle(objection.style.color)
                Text(objection.statement).font(.system(size: 10)).lineLimit(2)
            }
        }
        if node.objections.count > 3 {
            Text("+\(node.objections.count - 3) more").font(.system(size: 9)).foregroundStyle(.secondary)
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
            .foregroundStyle(node.tint)
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
                    if node.kind == .verdict { FiledObjections(node: node) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(node.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(node.strokeTint, lineWidth: 1.5))
    }

    @ViewBuilder private var menu: some View {
        if node.isProposed {
            Button("Fork into Claude Code", systemImage: "arrow.branch", action: onFork)
            Divider()
            Button("Remove this angle", systemImage: "trash", role: .destructive, action: onRemove)
        } else {
            if canDig {
                Button("Research further from here", systemImage: "arrow.triangle.branch", action: onDig)
            }
            if childCount > 0 {
                Button(isCollapsed ? "Expand" : "Collapse", systemImage: "chevron.down.square",
                       action: onToggleCollapse)
            }
            Button("Focus this path", systemImage: "scope", action: onFocus)
            if canRetry || canPrune {
                Divider()
                if canRetry { Button("Retry", systemImage: "arrow.clockwise", action: onRetry) }
                if canPrune {
                    Button("Prune this branch", systemImage: "scissors", role: .destructive,
                           action: onPrune)
                }
            }
        }
    }
}

/// A verdict in full: what was filed, how hard it lands, and the one task that would settle it. A
/// validator never edits the answer, so the follow-up is the whole point of reading one.
struct FiledObjections: View {
    let node: GraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if node.objections.isEmpty {
                Label(node.wasSkipped ? "This task did not run, so nothing here was checked."
                                      : "Nothing was filed against the answer.",
                      systemImage: node.stateStyle.icon)
                    .font(.caption)
                    .foregroundStyle(node.stateStyle.color)
            }
            ForEach(Array(node.objections.enumerated()), id: \.offset) { _, objection in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(objection.lens.uppercased())
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        Text(objection.severity.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(objection.style.color)
                    }
                    Text(objection.statement).font(.caption)
                    Label(objection.followup, systemImage: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a node hands the rail to read: the prose it produced and the evidence behind it. A running angle
/// has no report on disk, a finished one has a note — both arrive here as the same two fields, so the rail
/// never has to know which kind of run it is beside.
struct NodeReading {
    var writeup: String?
    var notePath: String?
    var evidence: EvidenceContext?
}

/// Long-form reading, beside the canvas rather than inside a node. A synthesis in a pannable box is worse
/// than a synthesis in a column; the graph stays the place you are while text gets to be text. It is the
/// reader, not a preview of it: markers resolve to numbered chips, the sources carry their seals, and
/// picking one opens the source itself beside the canvas.
struct ReadingRail: View {
    let node: GraphNode
    var live: LiveSnapshot?
    let graph: ResearchGraph
    var reading = NodeReading()
    @Binding var citation: Citation?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider()
            reader
        }
        .background(.background)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(node.rowLabel, systemImage: node.icon).font(.caption.weight(.semibold))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text(node.title).font(.headline).lineLimit(4)
            if let document = node.document {
                Link(document.url, destination: URL(string: document.url) ?? URL(fileURLWithPath: "/"))
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
    }

    /// The writeup as the reader reads it wherever there is one to read. A node still streaming, or one
    /// whose run kept no evidence, falls back to plain prose rather than to an empty reader.
    @ViewBuilder private var reader: some View {
        if let evidence = reading.evidence, let writeup = reading.writeup, !writeup.isEmpty {
            CitedReader(writeup: writeup, evidence: evidence.index, selected: $citation, documentID: node.id)
        } else if let evidence = reading.evidence, let path = reading.notePath {
            CitedNoteReader(path: path, evidence: evidence.index, selected: $citation)
        } else {
            streaming
        }
    }

    private var streaming: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if node.kind == .verdict { FiledObjections(node: node) }
                if let body = live?.output, !body.isEmpty {
                    MarkdownView(markdown: body)
                } else if let subtitle = node.subtitle {
                    Text(subtitle).font(.body)
                }
                if !cited.isEmpty {
                    Divider()
                    Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(cited) { source in sourceRow(source) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// A source and what the run can promise about it. An unvalidated run kept no snapshot to check a quote
    /// against, so its sources are listed unsealed rather than listed as if they had been checked.
    private func sourceRow(_ source: GraphNode) -> some View {
        let capture = source.document?.capture ?? .failed
        let seal = NodeStyle.seal(verified: graph.isValidated && capture == .ok)
        return VStack(alignment: .leading, spacing: 2) {
            Label(source.title, systemImage: NodeStyle.kind(.source).icon).font(.caption).lineLimit(1)
            Label(graph.isValidated ? capture.label : "unvalidated — nothing was captured",
                  systemImage: seal.icon)
                .font(.caption2).foregroundStyle(seal.color)
        }
    }

    private var cited: [GraphNode] {
        graph.children(of: node.id).filter { $0.kind == .source }
    }
}

private extension GraphNode {
    var style: NodeStyle { NodeStyle.node(self) }

    var stateStyle: NodeStyle { NodeStyle.state(of: self) }

    var icon: String { style.icon }

    var rowLabel: String { style.label }

    var tint: Color { NodeStyle.kind(kind).color }

    /// A passing verdict is its lens and a seal; one that filed says how much, because a count is the
    /// thing you decide whether to open on.
    var chipTitle: String {
        guard kind == .verdict, case let .judged(objections) = state, objections > 0 else { return title }
        return "\(rowLabel) · \(objections) objection\(objections == 1 ? "" : "s")"
    }

    var wasSkipped: Bool { kind == .verdict && state == .derived }

    /// A node with nothing to report is outlined in its own kind's colour, faintly — the outline is for the
    /// nodes that have something to say.
    var strokeTint: Color {
        stateStyle.isMuted ? stateStyle.color.opacity(0.45) : stateStyle.color
    }

    /// A pending question is drawn dashed because nothing has been spent on it yet — the outline is the
    /// difference between a request and a fact. A verdict's ring is heavier for the opposite reason: it is
    /// the pass or the fail, and it has to read at chip size.
    var strokeStyle: StrokeStyle {
        if isPending { return StrokeStyle(lineWidth: 1.5, dash: [5, 4]) }
        if wasSkipped { return StrokeStyle(lineWidth: 1, dash: [3, 3]) }
        if case .judged = state { return StrokeStyle(lineWidth: 2) }
        return StrokeStyle(lineWidth: 1)
    }

    var isPlanning: Bool { state == .asked(.planning) }

    var detailWord: String { kind == .synthesis ? "open points" : "findings" }

    var stateBadge: String? { stateStyle.badge }

    /// Nothing to read beside an angle that has not run yet — a proposed card opens into its own prompt,
    /// not into a rail with nothing in it.
    var deservesRail: Bool {
        guard !isProposed else { return false }
        return kind == .synthesis || kind == .inquiry || kind == .source || kind == .verdict
    }
}

private extension GraphEdge {
    var tint: Color { NodeStyle.edge(kind).color }
}

private extension RunStreamParser.ObjectionEvent {
    var style: NodeStyle { NodeStyle.objection(severity: severity) }
}

private extension Decimal {
    var moneyLabel: String {
        let value = NSDecimalNumber(decimal: self).doubleValue
        return value < 1 ? String(format: "$%.2f", value) : String(format: "$%.1f", value)
    }

    /// A ceiling is a promise, so it reads as dollars and cents rather than as a rounded number — and in
    /// dollars whatever the machine's locale is, because that is the currency it is charged in.
    var capLabel: String {
        formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }
}
