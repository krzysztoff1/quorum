import Foundation

/// A colour by name rather than by framework, so the table that decides what "complete" looks like can live
/// beside the model it describes instead of inside a view. Each surface resolves a token to its own paint
/// once, in one place, and no second opinion about green is possible.
public enum StyleTint: String, Sendable, Equatable, CaseIterable {
    case accent, blue, teal, green, yellow, orange, red, purple, pink, neutral
}

/// The one answer to "how is this drawn": an icon, a tint, the word that goes with it, and whether the
/// thing it describes is in flight (a spinner, not a glyph) or quiet (a muted outline). Kinds, statuses,
/// lifecycle states, timeline lanes, objections and verification seals all resolve through here, so a
/// verdict's pink and a blocking objection's red are each defined exactly once.
public struct NodeStyle: Sendable, Equatable {
    public let icon: String
    public let tint: StyleTint
    public let label: String
    public let showsProgress: Bool
    public let isMuted: Bool

    public init(icon: String, tint: StyleTint, label: String = "",
                showsProgress: Bool = false, isMuted: Bool = false) {
        self.icon = icon
        self.tint = tint
        self.label = label
        self.showsProgress = showsProgress
        self.isMuted = isMuted
    }

    /// The badge a card carries in its corner. Empty means the node has nothing worth saying about itself.
    public var badge: String? { label.isEmpty ? nil : label }
}

public extension NodeStyle {

    static func kind(_ kind: GraphNodeKind) -> NodeStyle {
        switch kind {
        case .question:     return NodeStyle(icon: "questionmark.circle", tint: .accent, label: "Question")
        case .inquiry:      return NodeStyle(icon: "magnifyingglass", tint: .blue, label: "Angle")
        case .source:       return NodeStyle(icon: "doc.text", tint: .teal, label: "Source")
        case .finding:      return NodeStyle(icon: "checkmark.seal", tint: .green, label: "Finding")
        case .conflict:     return NodeStyle(icon: "exclamationmark.triangle", tint: .orange, label: "Conflict")
        case .gap:          return NodeStyle(icon: "circle.dashed", tint: .purple, label: "Gap")
        case .synthesis:    return NodeStyle(icon: "square.stack.3d.up", tint: .accent, label: "Synthesis")
        case .verification: return NodeStyle(icon: "checkmark.shield", tint: .green, label: "Verified")
        case .verdict:      return NodeStyle(icon: "gavel", tint: .pink, label: "Verdict")
        }
    }

    /// A node as itself. Four gavels in a row say a verdict rank happened without saying what any of them
    /// looked at, so a verdict is drawn and named as the validator task that filed it; and the answer a dive
    /// was fused into is named as the answer rather than as one more synthesis among its rounds.
    static func node(_ node: GraphNode) -> NodeStyle {
        if node.isReconciled {
            return NodeStyle(icon: "arrow.triangle.merge", tint: kind(.synthesis).tint,
                             label: "Current answer")
        }
        guard node.kind == .verdict, let lens = node.lens, !lens.isEmpty else { return kind(node.kind) }
        return NodeStyle(icon: lensIcon(lens), tint: kind(.verdict).tint,
                         label: lens.replacingOccurrences(of: "_", with: " "))
    }

    private static func lensIcon(_ lens: String) -> String {
        switch lens {
        case "claim_sweep": return "text.magnifyingglass"
        case "coverage":    return "checklist"
        case "conflicts":   return "arrow.left.arrow.right"
        case "sources":     return "doc.text.magnifyingglass"
        case "structure":   return "curlybraces"
        default:            return kind(.verdict).icon
        }
    }

    /// What a node's own lifecycle says on it: the outline it is drawn in and the word in its corner. A
    /// validator task the run skipped is derived rather than judged, and must never read as a pass.
    static func state(of node: GraphNode) -> NodeStyle {
        if node.kind == .verdict, node.state == .derived {
            return NodeStyle(icon: "minus.circle", tint: .neutral, label: "SKIPPED")
        }
        switch node.state {
        case .asked(.planning):
            return NodeStyle(icon: kind(.question).icon, tint: .accent, label: "PLANNING", showsProgress: true)
        case .asked(.pending):   return NodeStyle(icon: "hand.raised.fill", tint: .orange, label: "PENDING")
        case .asked(.rejected):  return NodeStyle(icon: "xmark.circle", tint: .neutral, label: "REFUSED")
        case .asked(.expired):   return NodeStyle(icon: "clock.badge.xmark", tint: .neutral, label: "EXPIRED")
        case .asked(.approved):  return quiet(node.kind)
        case let .worked(status) where status == .running || status == .error:
            let style = self.status(status)
            return NodeStyle(icon: style.icon, tint: status == .running ? .blue : .red,
                             label: status == .running ? "RUNNING" : "FAILED",
                             showsProgress: style.showsProgress)
        case .worked:            return quiet(node.kind)
        case .judged(0):         return NodeStyle(icon: "checkmark.seal.fill", tint: .green, label: "HELD")
        case let .judged(count):
            return NodeStyle(icon: "exclamationmark.octagon.fill", tint: .red,
                             label: "\(count) OBJECTION\(count == 1 ? "" : "S")")
        case .derived:           return quiet(node.kind)
        }
    }

    private static func quiet(_ nodeKind: GraphNodeKind) -> NodeStyle {
        NodeStyle(icon: kind(nodeKind).icon, tint: kind(nodeKind).tint, isMuted: true)
    }

    static func status(_ status: TopicStatus) -> NodeStyle {
        switch status {
        case .queued:       return NodeStyle(icon: "circle.dotted", tint: .neutral, label: status.label)
        case .running:      return NodeStyle(icon: "circle.dashed", tint: .blue, label: status.label,
                                             showsProgress: true)
        case .complete:     return NodeStyle(icon: "checkmark.circle.fill", tint: .green, label: status.label)
        case .inconclusive: return NodeStyle(icon: "questionmark.circle.fill", tint: .yellow, label: status.label)
        case .haltedSpend, .haltedTime, .haltedManual, .error:
            return NodeStyle(icon: "exclamationmark.triangle.fill", tint: .red, label: status.label)
        case .skipped:      return NodeStyle(icon: "minus.circle", tint: .purple, label: status.label)
        }
    }

    /// A timeline lane, which is a status wearing its role: the synthesis and the citation check keep their
    /// own glyphs so a wall of angles doesn't swallow them, and anything in flight spins instead.
    static func lane(role: LaneRole, status: TopicStatus) -> NodeStyle {
        let outcome = self.status(status)
        guard !outcome.showsProgress else { return outcome }
        switch role {
        case .angle:     return outcome
        case .synthesis: return NodeStyle(icon: "sparkles", tint: laneTint(status), label: outcome.label)
        case .verify:    return NodeStyle(icon: "checkmark.shield", tint: laneTint(status), label: outcome.label)
        }
    }

    private static func laneTint(_ status: TopicStatus) -> StyleTint {
        status == .complete ? .green : .neutral
    }

    /// How hard an objection lands. Blocking is what buys another round, so it is the one that reads as a
    /// stop rather than as a note in the margin.
    static func objection(severity: String) -> NodeStyle {
        severity == "blocking"
            ? NodeStyle(icon: "exclamationmark.octagon.fill", tint: .red, label: severity)
            : NodeStyle(icon: "exclamationmark.circle", tint: .orange, label: severity)
    }

    /// A relation, drawn in the colour of what it relates. A judgement is pink because a verdict is pink;
    /// nothing else decides that twice.
    static func edge(_ kind: GraphEdgeKind) -> StyleTint {
        switch kind {
        case .spawned:      return .orange
        case .corroborates: return .teal
        case .contradicts:  return .orange
        case .cites:        return .teal
        case .judges:       return self.kind(.verdict).tint
        case .verifies:     return .green
        default:            return .neutral
        }
    }

    /// A citation chip, on the rung the run left it on. The two rungs that stand read in the reader's own
    /// accent; the one the sweep filed against reads as a warning, since it is drawn against the sentence
    /// it sits in; and the one with nothing behind it is hollow rather than coloured in.
    static func citation(_ tier: CitationTier) -> NodeStyle {
        switch tier {
        case .supported:
            return NodeStyle(icon: seal(verified: true).icon, tint: .accent, label: tier.label)
        case .close:
            return NodeStyle(icon: "checkmark.seal", tint: .accent, label: tier.label)
        case .unsupported:
            return NodeStyle(icon: "exclamationmark.triangle.fill", tint: .red, label: tier.label)
        case .unresolved:
            return NodeStyle(icon: seal(verified: false).icon, tint: .orange, label: tier.label,
                             isMuted: true)
        }
    }

    /// Whether a quote was found in the source it claims. The reader's rail and the canvas's source list
    /// say it with the same glyph, because they are the same claim about the same evidence.
    static func seal(verified: Bool) -> NodeStyle {
        verified
            ? NodeStyle(icon: "checkmark.seal.fill", tint: .green)
            : NodeStyle(icon: "questionmark.circle", tint: .orange)
    }
}
