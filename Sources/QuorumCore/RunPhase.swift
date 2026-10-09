import Foundation

extension FanOutPhase {
    /// The wire's word for what the run is doing. A phase this app has never heard of reads as research
    /// rather than stopping the run — but the two phases that are NOT research (waiting on a person, and
    /// the run arguing with its own draft) each keep their own name, because the header is a claim about
    /// what is happening and either one would make that claim false.
    public init(wire: String) {
        switch wire {
        case "planning":                 self = .planning
        case "awaiting_approval":        self = .awaitingApproval
        case "synthesizing", "reconciling": self = .synthesizing
        case "grounding":                self = .verifying
        case "validating":               self = .validating
        case "done":                     self = .done
        default:                         self = .researching
        }
    }

    /// Whether anything has run yet. Planning and the review that follows it are still a draft — nothing
    /// has been spent or spawned, so a run in either phase has nothing behind it yet.
    public var hasLaunched: Bool { self != .planning && self != .awaitingApproval }
}

/// What the run's header says it is doing, as a value rather than a switch inside a view — the sentence a
/// person reads about a run costing them money is worth a test.
public struct RunPhaseSummary: Sendable, Equatable {
    public var phase: FanOutPhase
    public var angleCount: Int
    public var proposedAngles: Int
    public var pendingApprovals: Int
    public var round: Int
    public var runningAngles: Int
    public var spendUSD: Decimal

    public init(phase: FanOutPhase, angleCount: Int = 0, proposedAngles: Int = 0,
                pendingApprovals: Int = 0, round: Int = 1, runningAngles: Int = 0,
                spendUSD: Decimal = 0) {
        self.phase = phase
        self.angleCount = angleCount
        self.proposedAngles = proposedAngles
        self.pendingApprovals = pendingApprovals
        self.round = round
        self.runningAngles = runningAngles
        self.spendUSD = spendUSD
    }

    public var blockedOnAPerson: Bool { phase == .awaitingApproval }

    public var showsProgress: Bool { !blockedOnAPerson }

    public var label: String {
        switch phase {
        case .planning:
            return "decomposing into \(angleCount) angles…"
        case .awaitingApproval:
            guard pendingApprovals == 0 else {
                return "waiting on you — \(pendingApprovals) proposed "
                       + (pendingApprovals == 1 ? "inquiry" : "inquiries")
            }
            return "\(proposedAngles) angles — edit them on the canvas, then research"
        case .researching:
            let roundPart = round > 1 ? "round \(round) · " : ""
            return "\(roundPart)\(runningAngles) blind agents in parallel · \(Reporter.money(spendUSD))"
        case .synthesizing:
            return "one agent reconciling all findings…"
        case .verifying:
            return "checking the answer against the sources it cites…"
        case .validating:
            return "checking the answer against its own sources"
        case .done:
            return "done"
        }
    }
}
