import Foundation

public enum GuardrailMapper {

    public struct PresetSpec: Equatable {
        public let effort: Effort
        public let sourceBudget: Int
        public let depth: Depth
        public let maxTurns: Int
        public let perTopicSpendCapUSD: Decimal
        public let runSpendCapUSD: Decimal
    }

    public static func spec(for preset: EffortPreset) -> PresetSpec {
        switch preset {
        case .draft:
            return PresetSpec(effort: .low, sourceBudget: 5, depth: .scan, maxTurns: 20,
                              perTopicSpendCapUSD: Decimal(string: "0.15")!, runSpendCapUSD: 1)
        case .standard:
            return PresetSpec(effort: .medium, sourceBudget: 10, depth: .thorough, maxTurns: 60,
                              perTopicSpendCapUSD: 10, runSpendCapUSD: 40)
        case .deep:
            return PresetSpec(effort: .xhigh, sourceBudget: 30, depth: .thorough, maxTurns: 120,
                              perTopicSpendCapUSD: 15, runSpendCapUSD: 60)
        case .max:
            return PresetSpec(effort: .max, sourceBudget: 50, depth: .thorough, maxTurns: 200,
                              perTopicSpendCapUSD: 20, runSpendCapUSD: 80)
        }
    }

    public static func runCostCeiling(angles: Int, perTopicCapUSD: Decimal, runCapUSD: Decimal) -> Decimal {
        guard angles > 0 else { return 0 }
        return min(runCapUSD, perTopicCapUSD * Decimal(angles + 1))
    }
}
