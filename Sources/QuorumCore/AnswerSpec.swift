import Foundation

public protocol OpenEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var unknownCase: Self { get }
}

public extension OpenEnum {
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? Self.unknownCase
    }
}

public enum DatumUnit: String, OpenEnum {
    case pct, pp, usd, eur, gbp, count, ratio, score, days, months, years, items, other, unknown
    public static let unknownCase = DatumUnit.unknown
}

public enum DatumScale: String, OpenEnum {
    case thousand = "k", million = "M", billion = "B", unknown
    public static let unknownCase = DatumScale.unknown
}

public enum DatumComparison: String, OpenEnum {
    case gt, lt, approx, unknown
    public static let unknownCase = DatumComparison.unknown
}

public enum DatumBasis: String, OpenEnum {
    case reported, derived, estimate, unknown
    public static let unknownCase = DatumBasis.unknown
}

public enum DatumTier: String, OpenEnum {
    case supported, close, unsupported, unresolved, unknown
    public static let unknownCase = DatumTier.unknown
}

public enum DatumTrace: String, OpenEnum {
    case quoted, derived, untraced, unknown
    public static let unknownCase = DatumTrace.unknown
}

public enum DatumConfidence: String, OpenEnum {
    case high, medium, low, unverified, unknown
    public static let unknownCase = DatumConfidence.unknown
}

public enum AnswerVerdict: String, OpenEnum {
    case settled, leaning, contested, inconclusive, unknown
    public static let unknownCase = AnswerVerdict.unknown
}

public enum AnswerSourceType: String, OpenEnum {
    case primary, vendor, seo, academic, news, unknown
    public static let unknownCase = AnswerSourceType.unknown
}

public struct DatumTrust: Codable, Sendable, Hashable {
    public let tier: DatumTier
    public let trace: DatumTrace
    public let confidence: DatumConfidence

    public init(tier: DatumTier, trace: DatumTrace, confidence: DatumConfidence) {
        self.tier = tier
        self.trace = trace
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case tier, trace, confidence }
}

public struct Datum: Codable, Sendable, Hashable {
    public let v: Double?
    public let lo: Double?
    public let hi: Double?
    public let unit: DatumUnit
    public let suffix: String?
    public let scale: DatumScale?
    public let cmp: DatumComparison?
    public let basis: DatumBasis
    public let cite: [String]
    public let asOf: String?
    public let scope: String?
    public let label: String?
    public let trust: DatumTrust?

    public init(v: Double? = nil, lo: Double? = nil, hi: Double? = nil, unit: DatumUnit, suffix: String? = nil,
                scale: DatumScale? = nil, cmp: DatumComparison? = nil, basis: DatumBasis, cite: [String],
                asOf: String? = nil, scope: String? = nil, label: String? = nil, trust: DatumTrust? = nil) {
        self.v = v
        self.lo = lo
        self.hi = hi
        self.unit = unit
        self.suffix = suffix
        self.scale = scale
        self.cmp = cmp
        self.basis = basis
        self.cite = cite
        self.asOf = asOf
        self.scope = scope
        self.label = label
        self.trust = trust
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, lo, hi, unit, suffix, scale, cmp, basis, cite
        case asOf = "as_of"
        case scope, label, trust
    }
}

public struct LabelledDatum: Codable, Sendable, Hashable {
    public let label: String
    public let value: Datum
}

public struct TierMix: Codable, Sendable, Hashable {
    public let supported: Int
    public let close: Int
    public let unsupported: Int
    public let unresolved: Int

    enum CodingKeys: String, CodingKey, CaseIterable { case supported, close, unsupported, unresolved }
}

public struct MixedBasis: Codable, Sendable, Hashable {
    public let asOf: Bool
    public let scope: Bool

    public init(asOf: Bool, scope: Bool) {
        self.asOf = asOf
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case asOf = "as_of", scope }
}

public struct AnswerRootProps: Codable, Sendable, Hashable {
    public let lead: String
    public let verdict: AnswerVerdict?

    enum CodingKeys: String, CodingKey, CaseIterable { case lead, verdict }
}

public struct GroupProps: Codable, Sendable, Hashable {
    public let title: String

    enum CodingKeys: String, CodingKey, CaseIterable { case title }
}

public struct ClaimProps: Codable, Sendable, Hashable {
    public let text: String
    public let confidence: DatumConfidence
    public let reason: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, confidence, reason }
}

public struct StatProps: Codable, Sendable, Hashable {
    public let value: Datum
    public let label: String
    public let of: Datum?
    public let context: Datum?
    public let caption: String

    enum CodingKeys: String, CodingKey, CaseIterable { case value, label, of, context, caption }
}

public struct RangeRow: Codable, Sendable, Hashable {
    public let label: String
    public let value: Datum
    public let group: String?
}

public struct AxisRange: Codable, Sendable, Hashable {
    public let min: Double?
    public let max: Double?
}

public struct RangeCompareProps: Codable, Sendable, Hashable {
    public let measure: String
    public let rows: [RangeRow]
    public let reference: LabelledDatum?
    public let axis: AxisRange?
    public let caption: String

    enum CodingKeys: String, CodingKey, CaseIterable { case measure, rows, reference, axis, caption }
}

public struct BarCompareProps: Codable, Sendable, Hashable {
    public let measure: String
    public let bars: [LabelledDatum]
    public let sort: String?
    public let caption: String
    public let mixedBasis: MixedBasis?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case measure, bars, sort, caption
        case mixedBasis = "mixed_basis"
    }
}

public enum Headline: Codable, Sendable, Hashable {
    case datum(Datum)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) } else { self = .datum(try container.decode(Datum.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .datum(let datum): try container.encode(datum)
        case .text(let text): try container.encode(text)
        }
    }

    public var datum: Datum? {
        if case .datum(let datum) = self { return datum }
        return nil
    }
}

public typealias TableCell = Headline

public struct ConflictSide: Codable, Sendable, Hashable {
    public let label: String
    public let headline: Headline
    public let summary: String
    public let sourceType: AnswerSourceType
    public let tierMix: TierMix?

    enum CodingKeys: String, CodingKey {
        case label, headline, summary
        case sourceType = "source_type"
        case tierMix = "tier_mix"
    }
}

public struct Leaning: Codable, Sendable, Hashable {
    public let side: Int
    public let why: String
}

public struct ConflictSplitProps: Codable, Sendable, Hashable {
    public let question: String
    public let sides: [ConflictSide]
    public let leaning: Leaning?
    public let settle: String?
    public let caption: String

    enum CodingKeys: String, CodingKey, CaseIterable { case question, sides, leaning, settle, caption }
}

public struct SourceCount: Codable, Sendable, Hashable {
    public let key: String
    public let n: Int

    public init(key: String, n: Int) {
        self.key = key
        self.n = n
    }
}

public struct SourceMixProps: Codable, Sendable, Hashable {
    public let scope: String
    public let by: String
    public let caption: String?
    public let counts: [SourceCount]?
    public let total: Int?

    enum CodingKeys: String, CodingKey, CaseIterable { case scope, by, caption, counts, total }
}

public struct TableColumn: Codable, Sendable, Hashable {
    public let key: String
    public let label: String
    public let align: String?
}

public struct EvidenceTableProps: Codable, Sendable, Hashable {
    public let columns: [TableColumn]
    public let rows: [[String: TableCell]]
    public let caption: String

    enum CodingKeys: String, CodingKey, CaseIterable { case columns, rows, caption }
}

public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

public enum AnswerElement: Codable, Sendable, Hashable {
    case answer(AnswerRootProps, children: [String])
    case group(GroupProps, children: [String])
    case claim(ClaimProps)
    case stat(StatProps)
    case rangeCompare(RangeCompareProps)
    case barCompare(BarCompareProps)
    case conflictSplit(ConflictSplitProps)
    case sourceMix(SourceMixProps)
    case evidenceTable(EvidenceTableProps)
    case unknown(type: String, raw: JSONValue)

    static let knownTypes = ["Answer", "Group", "Claim", "Stat", "RangeCompare", "BarCompare", "ConflictSplit", "SourceMix", "EvidenceTable"]

    static func wireKeys(of type: String) -> [String] {
        switch type {
        case "Answer": return AnswerRootProps.CodingKeys.allCases.map(\.rawValue)
        case "Group": return GroupProps.CodingKeys.allCases.map(\.rawValue)
        case "Claim": return ClaimProps.CodingKeys.allCases.map(\.rawValue)
        case "Stat": return StatProps.CodingKeys.allCases.map(\.rawValue)
        case "RangeCompare": return RangeCompareProps.CodingKeys.allCases.map(\.rawValue)
        case "BarCompare": return BarCompareProps.CodingKeys.allCases.map(\.rawValue)
        case "ConflictSplit": return ConflictSplitProps.CodingKeys.allCases.map(\.rawValue)
        case "SourceMix": return SourceMixProps.CodingKeys.allCases.map(\.rawValue)
        case "EvidenceTable": return EvidenceTableProps.CodingKeys.allCases.map(\.rawValue)
        default: return []
        }
    }

    private enum Keys: String, CodingKey { case type, props, children }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        let children = try container.decodeIfPresent([String].self, forKey: .children) ?? []
        switch type {
        case "Answer": self = .answer(try container.decode(AnswerRootProps.self, forKey: .props), children: children)
        case "Group": self = .group(try container.decode(GroupProps.self, forKey: .props), children: children)
        case "Claim": self = .claim(try container.decode(ClaimProps.self, forKey: .props))
        case "Stat": self = .stat(try container.decode(StatProps.self, forKey: .props))
        case "RangeCompare": self = .rangeCompare(try container.decode(RangeCompareProps.self, forKey: .props))
        case "BarCompare": self = .barCompare(try container.decode(BarCompareProps.self, forKey: .props))
        case "ConflictSplit": self = .conflictSplit(try container.decode(ConflictSplitProps.self, forKey: .props))
        case "SourceMix": self = .sourceMix(try container.decode(SourceMixProps.self, forKey: .props))
        case "EvidenceTable": self = .evidenceTable(try container.decode(EvidenceTableProps.self, forKey: .props))
        default: self = .unknown(type: type, raw: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(_, let raw) = self { return try raw.encode(to: encoder) }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .answer(let props, let children):
            try container.encode(props, forKey: .props)
            try container.encode(children, forKey: .children)
        case .group(let props, let children):
            try container.encode(props, forKey: .props)
            try container.encode(children, forKey: .children)
        case .claim(let props): try container.encode(props, forKey: .props)
        case .stat(let props): try container.encode(props, forKey: .props)
        case .rangeCompare(let props): try container.encode(props, forKey: .props)
        case .barCompare(let props): try container.encode(props, forKey: .props)
        case .conflictSplit(let props): try container.encode(props, forKey: .props)
        case .sourceMix(let props): try container.encode(props, forKey: .props)
        case .evidenceTable(let props): try container.encode(props, forKey: .props)
        case .unknown: break
        }
    }

    public var type: String {
        switch self {
        case .answer: return "Answer"
        case .group: return "Group"
        case .claim: return "Claim"
        case .stat: return "Stat"
        case .rangeCompare: return "RangeCompare"
        case .barCompare: return "BarCompare"
        case .conflictSplit: return "ConflictSplit"
        case .sourceMix: return "SourceMix"
        case .evidenceTable: return "EvidenceTable"
        case .unknown(let type, _): return type
        }
    }

    public var children: [String] {
        switch self {
        case .answer(_, let children), .group(_, let children): return children
        default: return []
        }
    }
}

public struct AnswerSpec: Codable, Sendable, Hashable {
    public let v: Int
    public let root: String
    public let elements: [String: AnswerElement]

    public init(v: Int = 1, root: String, elements: [String: AnswerElement]) {
        self.v = v
        self.root = root
        self.elements = elements
    }
}
