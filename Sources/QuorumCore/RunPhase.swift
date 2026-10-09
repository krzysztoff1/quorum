import Foundation

extension FanOutPhase {
    public init(wire: String) {
        switch wire {
        case "planning":                    self = .planning
        case "synthesizing", "reconciling": self = .synthesizing
        case "grounding":                   self = .verifying
        case "validating":                  self = .validating
        case "done":                        self = .done
        default:                            self = .researching
        }
    }

    public var hasLaunched: Bool { self != .planning }
}

public struct RunPhaseSummary: Sendable, Equatable {
    public var phase: FanOutPhase
    public var angleCount: Int
    public var round: Int
    public var runningAngles: Int
    public var spendUSD: Decimal

    public init(phase: FanOutPhase, angleCount: Int = 0, round: Int = 1, runningAngles: Int = 0,
                spendUSD: Decimal = 0) {
        self.phase = phase
        self.angleCount = angleCount
        self.round = round
        self.runningAngles = runningAngles
        self.spendUSD = spendUSD
    }

    public var label: String {
        switch phase {
        case .planning:
            return "decomposing into \(angleCount) angles…"
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
