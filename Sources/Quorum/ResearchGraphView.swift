import SwiftUI
import AppKit
import QuorumCore

/// The run, as the surface you work on rather than a picture beside it. Nodes carry their own results, a
/// pending question is approved on its card, and any node can be dug into. Edges are drawn in a `Canvas`
/// (immediate mode, cheap at every zoom); nodes are real views above it, because they hold buttons, live
/// text and heights that change when one is opened.
struct ResearchGraphView: View {
    let graph: ResearchGraph
    /// Off where the surface around the canvas already carries the notice — a finished run's header strip
    /// says it once, above the graph, rather than twice on the same screen.
    var showsUnvalidatedBanner = true
    var live: (String) -> LiveSnapshot? = { _ in nil }
    var onApprove: (String) -> Void = { _ in }
    var onReject: (String) -> Void = { _ in }
    /// Nil where digging is not on offer — a finished run's canvas draws no affordance it cannot honour.
    var onDig: ((GraphNode) -> Void)?
    var onPrune: (String) -> Void = { _ in }
    var onRetry: (String) -> Void = { _ in }
    /// What the rail beside the canvas reads for a node — the same reader a finished run gets, fed live.
    var reading: (GraphNode) -> NodeReading = { _ in NodeReading() }
    var bulkApprovals: BulkApprovals?
    /// A node ⌘K asked for. The canvas lights its path and opens it, then tells the caller it has, so the
    /// same node can be asked for again.
    var reveal: String?
    var onRevealed: () -> Void = {}
    /// False only for the dev snapshot: `ImageRenderer` draws nothing inside a `ScrollView`, so a picture of
    /// the whole graph is rendered unscrolled.
    var scrolls = true

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
    @State private var viewport = CanvasViewport()
    @State private var viewportSize: CGSize = .zero
    @State private var fitted = false
    @State private var placement = PlacedGraph(frames: [], bounds: .zero)
    /// The chip the reader picked, and so the source that opens beside the canvas. Cleared when the rail
    /// moves to another node: a quote is only a quote of the thing being read.
    @State private var citation: Citation?

    private var layout: GraphLayout { GraphLayout.best(for: visible) }

    /// Layout is a pure function of the graph, so the first frame can draw it rather than wait for the
    /// reflow `onAppear` schedules — an empty canvas is never the right first thing to show.
    private var placed: PlacedGraph {
        placement.frames.isEmpty ? layout.place(visible, sizes: measured) : placement
    }

    private var measured: [String: CGSize] {
        Dictionary(uniqueKeysWithValues: visible.nodes.map {
            ($0.id, GraphNodeCard.size(for: $0, detail: detail(for: $0)))
        })
    }

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
                    .frame(width: 480)
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
        Group {
            if scrolls { interactiveBoard } else { board.padding(24) }
        }
        .background(CanvasSurface.background)
        .overlay(alignment: .top) { unvalidatedBanner }
        .overlay(alignment: .topTrailing) { bulkApprovalBar }
        .overlay(alignment: .bottomTrailing) { controls }
    }

    /// What the zoom can still afford to draw, shared with the pure viewport model so the cutoffs the
    /// tests pin are the cutoffs the canvas uses.
    private var lod: CanvasViewport { viewport }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in draw(grid: context, size: size) }
                .frame(width: placed.bounds.width, height: placed.bounds.height)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !hasLiveWires)) { timeline in
                Canvas { context, _ in
                    draw(edges: context, at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(width: placed.bounds.width, height: placed.bounds.height)
            ForEach(visible.nodes) { node in
                if let frame = placed.frame(node.id), onScreen(frame.rect) {
                    nodeView(node)
                        .frame(width: frame.rect.width, height: frame.rect.height, alignment: .topLeading)
                        .offset(x: frame.rect.minX - placed.bounds.minX,
                                y: frame.rect.minY - placed.bounds.minY)
                        .opacity(dimmed(node) ? 0.32 : 1)
                }
            }
        }
        .frame(width: placed.bounds.width, height: placed.bounds.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.3), value: placement)
    }

    /// The board under the viewport's transform, with the viewport's hands over it. The board itself
    /// never scrolls — the transform is the navigation, so a zoom can hold the cursor's point still and
    /// ⌘K can put a named node in the middle of the screen.
    private var interactiveBoard: some View {
        GeometryReader { proxy in
            board
                .scaleEffect(viewport.zoom, anchor: .topLeading)
                .offset(x: viewport.pan.x, y: viewport.pan.y)
                .onAppear { viewportSize = proxy.size; fitFreshGraph() }
                .onChange(of: proxy.size) { viewportSize = proxy.size }
        }
        .clipped()
        .contentShape(Rectangle())
        .background(PanZoomCatcher(
            onPan: { viewport = viewport.panned(by: $0) },
            onWheelZoom: { viewport = viewport.zoomed(byWheel: $0, about: $1) },
            onMagnify: { viewport = viewport.zoomed(to: viewport.zoom * $0, about: $1) }))
    }

    /// A card safely off-screen is a card not built: the realized view tree tracks the viewport, padded a
    /// rank in every direction so panning never shows a card popping into existence.
    private func onScreen(_ rect: CGRect) -> Bool {
        guard scrolls, viewportSize != .zero else { return true }
        return viewport.visibleWorldRect(in: viewportSize)
            .insetBy(dx: -240, dy: -240)
            .intersects(rect.offsetBy(dx: -placed.bounds.minX, dy: -placed.bounds.minY))
    }

    /// The first laid-out graph arrives fitted to the window; everything after that is the reader's own
    /// navigation, which a reflow must never yank away.
    private func fitFreshGraph() {
        guard !fitted, placed.bounds.width > 0, viewportSize != .zero else { return }
        fitted = true
        viewport = .fitting(CGRect(origin: .zero, size: placed.bounds.size), in: viewportSize)
    }

    /// The source behind the chip that was picked, opened beside the prose quoting it rather than in place
    /// of it — the point of a citation is reading both at once.
    @ViewBuilder private func sourceInspector(for node: GraphNode) -> some View {
        if let citation, let context = reading(node).evidence {
            Divider()
            CitedSourceInspector(citation: citation, document: context.index.document(for: citation),
                                 evidenceDir: context.directory, grounding: context.grounding,
                                 tier: context.index.tier(citation.id)) {
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
        center(on: reveal)
        onRevealed()
    }

    /// The jump itself: the named node lands in the middle of the screen, at whatever zoom the reader
    /// already chose.
    private func center(on id: String) {
        let landed = layout.place(visible, sizes: measured, previous: placement)
        guard scrolls, viewportSize != .zero, let frame = landed.frame(id) else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            viewport = viewport.centered(on: frame.rect.offsetBy(dx: -landed.bounds.minX,
                                                                 dy: -landed.bounds.minY),
                                         in: viewportSize)
        }
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

    /// The board's spatial reference: one path of dots, faint enough to sit behind every wire and fading
    /// out as the zoom falls away, where it would otherwise read as noise.
    private func draw(grid context: GraphicsContext, size: CGSize) {
        let alpha = lod.gridAlpha
        guard alpha > 0 else { return }
        let spacing = CanvasSurface.gridSpacing
        let radius = CanvasSurface.dotRadius
        var dots = Path()
        var y = spacing / 2
        while y < size.height {
            var x = spacing / 2
            while x < size.width {
                dots.addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        context.fill(dots, with: .color(CanvasSurface.grid.opacity(alpha)))
    }

    private func draw(edges context: GraphicsContext, at time: TimeInterval) {
        for edge in visible.edges {
            guard let route = placed.route(edge) else { continue }
            var path = Path()
            path.move(to: shifted(route.start))
            path.addCurve(to: shifted(route.end),
                          control1: shifted(route.control1), control2: shifted(route.control2))
            let strong = lit.contains(edge.from) && lit.contains(edge.to)
            let faded = !(lit.isEmpty || strong)
            let tint = edge.tint.opacity(faded ? 0.16 : edge.weight.opacity)
            context.stroke(path, with: .color(tint), style: stroke(for: edge, at: time))
            if lod.showsPorts {
                draw(port: shifted(route.start), tint: tint, in: context)
                draw(port: shifted(route.end), tint: tint, in: context)
            }
            if let label = edge.label, lod.showsEdgeLabels {
                draw(label, at: shifted(route.midpoint), faded: faded, in: context)
            }
        }
    }

    /// A wire with work at either end runs: the dash marches from the parent toward the child at a pace
    /// the eye reads as progress rather than as alarm. Everything settled is drawn still.
    private func stroke(for edge: GraphEdge, at time: TimeInterval) -> StrokeStyle {
        guard wireIsLive(edge) else {
            return StrokeStyle(lineWidth: edge.weight.lineWidth, lineCap: .round, lineJoin: .round,
                               dash: edge.weight.dash)
        }
        return StrokeStyle(lineWidth: edge.weight.lineWidth, lineCap: .round, lineJoin: .round,
                           dash: [6, 6],
                           dashPhase: -CGFloat(time * 24).truncatingRemainder(dividingBy: 12))
    }

    /// A port: the wire's own point of contact, punched out of the board so the line reads as plugged in
    /// rather than as touching.
    private func draw(port point: CGPoint, tint: Color, in context: GraphicsContext) {
        let socket = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: socket), with: .color(CanvasSurface.background))
        context.stroke(Path(ellipseIn: socket.insetBy(dx: 0.75, dy: 0.75)),
                       with: .color(tint), lineWidth: 1.5)
    }

    private func wireIsLive(_ edge: GraphEdge) -> Bool {
        isBusy(edge.from) || isBusy(edge.to)
    }

    private func isBusy(_ id: String) -> Bool {
        guard let node = visible.node(id) else { return false }
        return NodeStyle.state(of: node).showsProgress
    }

    private var hasLiveWires: Bool {
        visible.edges.contains { wireIsLive($0) }
    }

    /// An edge's word sits on the wire it belongs to, so it is drawn on a plate of its own — a line running
    /// through the middle of a word costs the reader both.
    private func draw(_ label: String, at point: CGPoint, faded: Bool, in context: GraphicsContext) {
        let styled = Text(label).font(.caption.weight(.medium))
            .foregroundStyle(faded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        let text = context.resolve(styled)
        let size = text.measure(in: CGSize(width: 220, height: 40))
        let plate = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 3,
                           width: size.width + 12, height: size.height + 6)
        context.fill(Path(roundedRect: plate, cornerRadius: 6),
                     with: .color(CanvasSurface.background))
        context.draw(text, at: point, anchor: .center)
    }

    private func shifted(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - placed.bounds.minX, y: point.y - placed.bounds.minY)
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
            canDig: onDig != nil && graph.canDig(node.id),
            canPrune: graph.canPrune(node.id),
            canRetry: graph.canRetry(node.id),
            onOpen: { if node.deservesRail { opened = opened == node.id ? nil : node.id } },
            onFocus: { focused = focused == node.id ? nil : node.id },
            onToggleDetail: { toggleDetail(node.id) },
            onToggleCollapse: { toggleCollapse(node.id) },
            onApprove: { onApprove(node.id) },
            onReject: { onReject(node.id) },
            onDig: { onDig?(node) },
            onPrune: { onPrune(node.id) },
            onRetry: { onRetry(node.id) })
    }

    private func detail(for node: GraphNode) -> GraphNodeDetail {
        collapsed.contains(node.id) || lod.isChipZoom ? .chip : .card
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
        placement = layout.place(visible, sizes: measured, previous: placement)
        fitFreshGraph()
    }

    /// A run with no search key captured nothing, so nothing on this canvas was checked against a source.
    /// It says so on the canvas itself rather than leaving the absence of a chip to carry the message.
    @ViewBuilder private var unvalidatedBanner: some View {
        if !graph.isValidated, showsUnvalidatedBanner {
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
            Button { nudgeZoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { nudgeZoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { fitToWindow() } label: { Image(systemName: "rectangle.arrowtriangle.2.inward") }
                .help("Fit the whole run in the window")
            Text(layout.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private func nudgeZoom(by factor: CGFloat) {
        let middle = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        withAnimation(.easeOut(duration: 0.2)) {
            viewport = viewport.zoomed(to: viewport.zoom * factor, about: middle)
        }
    }

    private func fitToWindow() {
        guard placed.bounds.width > 0, viewportSize != .zero else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            viewport = .fitting(CGRect(origin: .zero, size: placed.bounds.size), in: viewportSize)
        }
    }
}

enum GraphNodeDetail { case chip, card }

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

    @State private var isHovered = false
    @State private var glowPulse = false

    /// One type scale for every card, set where it can be read on a canvas rather than in a sidebar: the
    /// rubric is the row's kind, the prose is everything the node actually says.
    static let rubric = Font.system(size: 10.5, weight: .bold)
    static let prose = Font.system(size: 11.5)

    static let chipSize = CGSize(width: 158, height: 44)
    static let cardWidth: CGFloat = 280

    /// Detail cards are narrower than the structure they hang off: ten findings at full width is a rank
    /// three thousand points across, which is not a diagram anyone reads.
    static let detailWidth: CGFloat = 200

    /// A verdict's chip carries the lens and, when it filed something, the count — "coverage · 2
    /// objections" does not fit the width a one-word chip was sized for.
    static let verdictChipSize = CGSize(width: 212, height: 44)

    /// A quorum is five cards wide on every draft of the answer, so a verdict is drawn narrower than the
    /// work it judges — and one that filed nothing is a line, not a card. Sized the other way round, the
    /// critics are the widest rank on the canvas and the run reads as being about them.
    static let verdictWidth: CGFloat = 236
    static let verdictHeaderHeight: CGFloat = 24
    static let objectionRowHeight: CGFloat = 38

    static func size(for node: GraphNode, detail: GraphNodeDetail) -> CGSize {
        switch detail {
        case .chip: return node.kind == .verdict ? verdictChipSize : chipSize
        case .card: return CGSize(width: width(for: node), height: cardHeight(for: node))
        }
    }

    private static func width(for node: GraphNode) -> CGFloat {
        switch node.kind {
        case _ where node.kind.isDetail: return detailWidth
        case .verdict:                   return verdictWidth
        default:                         return cardWidth
        }
    }

    private static func cardHeight(for node: GraphNode) -> CGFloat {
        switch node.kind {
        case .source, .finding, .gap:  return 90
        case .question where node.isPending:  return 172
        case .question where node.isPlanning: return 158
        case .question:                return 56 + titleHeight(node)
        case .verdict where node.objections.isEmpty: return verdictHeaderHeight + 30
        case .verdict:
            return verdictHeaderHeight + CGFloat(min(node.objections.count, 3)) * objectionRowHeight + 14
        default:
            return (node.restatesTheQuestion ? 72 : 86) + titleHeight(node) + subtitleHeight(node)
        }
    }

    /// Heights are estimated from the text rather than measured, so a card is as tall as what it says and
    /// the layout stays a pure function of the graph. The estimate is the same one the `lineLimit`s enforce,
    /// so a card can crop its prose but never crop it out of sight.
    private static func titleHeight(_ node: GraphNode) -> CGFloat {
        18 * CGFloat(lineCount(node.title, perLine: 36, limit: node.kind == .question ? 3 : 2))
    }

    private static func subtitleHeight(_ node: GraphNode) -> CGFloat {
        guard !node.restatesTheQuestion, let text = node.subtitle ?? node.reason, !text.isEmpty
        else { return 0 }
        return 15 * CGFloat(lineCount(text, perLine: 46, limit: 2))
    }

    private static func lineCount(_ text: String, perLine: Int, limit: Int) -> Int {
        min(limit, max(1, (text.count + perLine - 1) / perLine))
    }

    @ViewBuilder var body: some View {
        Group {
            switch detail {
            case .chip: chip
            case .card: card
            }
        }
        .contextMenu { menu }
        .onTapGesture(count: 2) { onFocus() }
        .onTapGesture { onOpen() }
        .overlay(alignment: .topTrailing) { digButton }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .onAppear(perform: startGlow)
        .onChange(of: node.state) { startGlow() }
    }

    /// The card's state, visible from across the canvas: work in flight breathes in its own colour, a
    /// judgement or a failure holds a steady ring of light, and everything settled casts only its shadow.
    private var glowTint: Color? {
        if node.stateStyle.showsProgress { return node.stateStyle.color }
        if case .judged = node.state { return node.stateStyle.color }
        if node.state == .worked(.error) { return node.stateStyle.color }
        return nil
    }

    private func startGlow() {
        guard node.stateStyle.showsProgress else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glowPulse = true }
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

    /// Cards are opaque. A translucent fill lets the wires behind a node show through its own prose, which
    /// is the difference between a diagram and a smear.
    private func plate(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.background)
            .overlay(RoundedRectangle(cornerRadius: radius).fill(node.plateTint.opacity(0.12)))
            .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
            .shadow(color: glowTint?.opacity(0.45) ?? .clear,
                    radius: node.stateStyle.showsProgress ? (glowPulse ? 12 : 5) : 7)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: node.icon).font(.caption)
            Text(node.chipTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if childCount > 0 && isCollapsed {
                Text("\(childCount)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.secondary.opacity(0.18), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(plate(10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    /// A verdict's header already names the lens that filed it, so repeating the lens as a title says
    /// "coverage" twice on a card whose whole job is to carry what coverage found.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if node.kind != .verdict {
                Text(node.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(node.kind == .question ? 3 : 2)
                    .multilineTextAlignment(.leading)
            }
            if node.isPending { pendingBody }
            else if node.isPlanning { planningBody }
            else if node.kind == .verdict { verdictBody }
            else { resultBody }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(plate(12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(node.strokeTint, style: node.strokeStyle))
    }

    private var header: some View {
        HStack(spacing: 5) {
            if node.stateStyle.showsProgress {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
                Image(systemName: node.icon).font(.caption)
            }
            Text(node.rowLabel.uppercased()).font(Self.rubric)
            if let round = node.roundLabel {
                Text(round).font(Self.rubric).foregroundStyle(.tertiary)
            }
            Spacer()
            if let badge = node.stateBadge {
                Text(badge).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(node.strokeTint)
            }
            if node.costUSD > 0 {
                Text(node.costUSD.moneyLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(node.plateTint)
    }

    @ViewBuilder private var pendingBody: some View {
        if let why = node.reason {
            Text("why: \(why)").font(Self.prose).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 6) {
            Button("Approve", action: onApprove).buttonStyle(.borderedProminent).controlSize(.mini)
            Button("Reject", action: onReject).buttonStyle(.bordered).controlSize(.mini)
            Spacer()
            if let estimate = node.estimatedCostUSD {
                Text("~\(estimate.moneyLabel)").font(Self.prose).foregroundStyle(.secondary)
            }
        }
    }

    /// The decomposition, streaming on the node it is decomposing. The planner's reasoning is the first
    /// thing the run produces, so the canvas should be where it lands rather than a screen you leave.
    @ViewBuilder private var planningBody: some View {
        if let subtitle = node.subtitle {
            Text(subtitle).font(Self.prose).foregroundStyle(.secondary)
        }
        if let stream = live, !stream.thinkingTail.isEmpty {
            Text(stream.thinkingTail)
                .font(.system(size: 10, design: .monospaced))
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
            Text(node.wasSkipped ? "not run — nothing was checked" : "nothing filed against the answer")
                .font(Self.prose)
                .foregroundStyle(.secondary)
        }
        ForEach(Array(node.objections.prefix(3).enumerated()), id: \.offset) { _, objection in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: objection.style.icon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(objection.style.color)
                Text(objection.statement).font(Self.prose).lineLimit(2)
            }
        }
        if node.objections.count > 3 {
            Text("+\(node.objections.count - 3) more").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var resultBody: some View {
        if !node.restatesTheQuestion, let subtitle = node.subtitle, !subtitle.isEmpty {
            Text(subtitle).font(Self.prose).foregroundStyle(.secondary).lineLimit(2)
        } else if let streaming = live?.output, !streaming.isEmpty {
            Text(streaming.suffix(120)).font(Self.prose).foregroundStyle(.secondary).lineLimit(2)
        } else if let reason = node.reason {
            Text(reason).font(Self.prose).foregroundStyle(.secondary).lineLimit(2)
        }
        if detailCount > 0 {
            Button(action: onToggleDetail) {
                Label("\(detailCount) \(node.detailWord)", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(node.tint.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(node.tint)
            .help(isExpanded ? "Fold the \(node.detailWord) back into the card"
                             : "Lay the \(node.detailWord) out on the canvas")
        }
    }

    @ViewBuilder private var menu: some View {
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
    var evidence: EvidenceContext?
    var topic: TopicTarget?
    /// The audit the digest used to be a whole screen for — what was done, how solid it is, what is still
    /// open. It belongs to the answer, so it rides beside the answer rather than instead of the graph.
    var audit: TopicTarget?
    /// What the run's own validators made of the answer. Nil where nothing judged it, which is not the
    /// same as nothing having been found.
    var validation: RunValidation?
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

    /// The answer is three readings of one thing: what it says, how it was reached, and what was filed
    /// against it. Every other node is only ever the first.
    private enum Tab: String, CaseIterable, Identifiable {
        case answer = "Answer", audit = "Audit", validation = "Validation"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .answer

    private var tabs: [Tab] {
        [.answer] + (reading.audit == nil ? [] : [.audit]) + (reading.validation == nil ? [] : [.validation])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Divider()
            switch tabs.contains(tab) ? tab : .answer {
            case .answer:     reader
            case .audit:      audit
            case .validation: validationTab
            }
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
            HStack(spacing: 12) {
                if let topic = reading.topic {
                    NavigationLink(value: topic) {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Continue this topic's own research session, or hand it to the Claude Code CLI")
                }
            }
            if tabs.count > 1 {
                Picker("", selection: $tab) { ForEach(tabs) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(12)
    }

    @ViewBuilder private var audit: some View {
        if let target = reading.audit {
            ScrollView {
                SynthesisSummary(target: target) { NSWorkspace.shared.open($0) }.padding(16)
            }
        }
    }

    @ViewBuilder private var validationTab: some View {
        if let validation = reading.validation { ValidationTab(validation: validation) }
    }

    /// The writeup as the reader reads it wherever there is one to read. A node still streaming, or one
    /// whose run kept no evidence, falls back to plain prose rather than to an empty reader.
    @ViewBuilder private var reader: some View {
        if let evidence = reading.evidence, let writeup = reading.writeup, !writeup.isEmpty {
            CitedReader(writeup: writeup, evidence: evidence.index, selected: $citation, documentID: node.id)
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

    /// What a card is washed in. Everything is its own kind — except a verdict, which is what it decided:
    /// a rank of five pink cards says a quorum sat, and nothing about which way any of them went.
    var plateTint: Color { kind == .verdict ? stateStyle.color : tint }

    /// Which round bought this card, on the card, once there has been more than one. A canvas six ranks
    /// deep otherwise makes the reader count wires back to the answer to place a card in the loop.
    /// A draft's subtitle is the question the whole run is asking, and that question is already the card
    /// every wire on the canvas descends from. Three drafts restating it spend three cards of the reader's
    /// attention on the one thing they cannot have forgotten.
    var restatesTheQuestion: Bool { kind == .synthesis }

    var roundLabel: String? {
        guard round > 1, kind == .inquiry || kind == .synthesis || kind == .verdict else { return nil }
        return "R\(round)"
    }

    /// A passing verdict is its lens and a seal; one that filed says how much, because a count is the
    /// thing you decide whether to open on.
    var chipTitle: String {
        guard kind == .verdict, case let .judged(objections) = state, objections > 0 else { return title }
        return "\(rowLabel) · \(objections) objection\(objections == 1 ? "" : "s")"
    }

    var wasSkipped: Bool { kind == .verdict && state == .derived }

    /// A node with nothing to report is outlined in its own kind's colour, faintly — the outline is for the
    /// nodes that have something to say. Detail cards are the exception: a conflict or a gap IS what it
    /// says, and drawn as mutedly as an idle angle the layer worth exploring reads as dead weight.
    var strokeTint: Color {
        if kind.isDetail { return tint.opacity(0.75) }
        return stateStyle.isMuted ? stateStyle.color.opacity(0.45) : stateStyle.color
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

    var deservesRail: Bool {
        kind == .synthesis || kind == .inquiry || kind == .source || kind == .verdict
    }
}

private extension GraphEdge {
    var tint: Color { NodeStyle.edge(kind).color }

    /// How loudly a wire is drawn. The run's own descent — question into angles into an answer — is the
    /// line the reader follows, so it is the only one drawn at full strength; a judgement and a shared
    /// document are remarks about that descent and are drawn as remarks, or five critics per draft
    /// out-shout the thing they are judging.
    var weight: (lineWidth: CGFloat, opacity: Double, dash: [CGFloat]) {
        switch kind {
        case .corroborates:        return (1, 0.6, [3, 4])
        case .judges, .verifies:   return (1.25, 0.5, [])
        default:                   return (1.75, 0.8, [])
        }
    }
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
