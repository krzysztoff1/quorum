import Foundation

public enum FanOutPhase: String, Sendable, Equatable, CaseIterable {
    case planning, researching, synthesizing, verifying, validating, done
}

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
}
