// Hand-written Codable mirror of the engine's ResolvedSpec (spikes/json-render/src/catalog.ts, mode "resolved").
// Kept in sync by the drift test, which walks schema/qvs-resolved.schema.json. Decode-only: the app never writes specs.
import Foundation

// MARK: - Spec

public struct QVSSpec: Decodable, Sendable {
    public let v: Int
    public let root: String
    public let elements: [String: QVSElement]

    public static func decode(_ data: Data) throws -> QVSSpec { try JSONDecoder().decode(QVSSpec.self, from: data) }
    public var rootElement: QVSElement? { elements[root] }
}

public struct QVSElement: Decodable, Sendable {
    public let body: Body
    public let children: [String]

    public enum Body: Sendable {
        case answer(Answer), group(Group), claim(Claim), stat(Stat)
        case rangeCompare(RangeCompare), barCompare(BarCompare), trendLine(TrendLine), smallMultiples(SmallMultiples)
        case conflictSplit(ConflictSplit), sourceMix(SourceMix), evidenceTable(EvidenceTable)
        case timeline(Timeline), decisionMatrix(DecisionMatrix), quadrant(Quadrant), argumentMap(ArgumentMap)
        /// A type this build doesn't know (newer engine). The renderer shows the caption-less fallback, never crashes.
        case unknown(String)
    }

    /// Every `type` this mirror decodes, with its props' coding keys — the drift test compares both to the JSON Schema.
    public static let known: [String: [String]] = [
        "Answer": Answer.propKeys, "Group": Group.propKeys, "Claim": Claim.propKeys, "Stat": Stat.propKeys,
        "RangeCompare": RangeCompare.propKeys, "BarCompare": BarCompare.propKeys, "TrendLine": TrendLine.propKeys,
        "SmallMultiples": SmallMultiples.propKeys, "ConflictSplit": ConflictSplit.propKeys, "SourceMix": SourceMix.propKeys,
        "EvidenceTable": EvidenceTable.propKeys, "Timeline": Timeline.propKeys, "DecisionMatrix": DecisionMatrix.propKeys,
        "Quadrant": Quadrant.propKeys, "ArgumentMap": ArgumentMap.propKeys,
    ]

    private enum K: String, CodingKey { case type, props, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        func p<T: Decodable>(_: T.Type) throws -> T { try c.decode(T.self, forKey: .props) }
        switch type {
        case "Answer": body = .answer(try p(Answer.self))
        case "Group": body = .group(try p(Group.self))
        case "Claim": body = .claim(try p(Claim.self))
        case "Stat": body = .stat(try p(Stat.self))
        case "RangeCompare": body = .rangeCompare(try p(RangeCompare.self))
        case "BarCompare": body = .barCompare(try p(BarCompare.self))
        case "TrendLine": body = .trendLine(try p(TrendLine.self))
        case "SmallMultiples": body = .smallMultiples(try p(SmallMultiples.self))
        case "ConflictSplit": body = .conflictSplit(try p(ConflictSplit.self))
        case "SourceMix": body = .sourceMix(try p(SourceMix.self))
        case "EvidenceTable": body = .evidenceTable(try p(EvidenceTable.self))
        case "Timeline": body = .timeline(try p(Timeline.self))
        case "DecisionMatrix": body = .decisionMatrix(try p(DecisionMatrix.self))
        case "Quadrant": body = .quadrant(try p(Quadrant.self))
        case "ArgumentMap": body = .argumentMap(try p(ArgumentMap.self))
        default: body = .unknown(type)
        }
    }

    public var type: String {
        switch body {
        case .answer: "Answer"; case .group: "Group"; case .claim: "Claim"; case .stat: "Stat"
        case .rangeCompare: "RangeCompare"; case .barCompare: "BarCompare"; case .trendLine: "TrendLine"
        case .smallMultiples: "SmallMultiples"; case .conflictSplit: "ConflictSplit"; case .sourceMix: "SourceMix"
        case .evidenceTable: "EvidenceTable"; case .timeline: "Timeline"; case .decisionMatrix: "DecisionMatrix"
        case .quadrant: "Quadrant"; case .argumentMap: "ArgumentMap"; case .unknown(let t): t
        }
    }
}

/// Props structs list their keys so the drift test can compare them to the schema.
public protocol QVSProps: Decodable, Sendable { static var propKeys: [String] { get } }
extension QVSProps where Self: Decodable {
    static func keys<K: CodingKey & CaseIterable>(_: K.Type) -> [String] { K.allCases.map(\.stringValue) }
}

// MARK: - Datum & trust

public enum Unit: String, Decodable, Sendable { case pct, pp, usd, count, ratio, score, days, months, items }
public enum Tier: String, Decodable, Sendable { case supported, close, unsupported, unresolved }
public enum Confidence: String, Decodable, Sendable { case high, medium, low, unverified }
public enum SourceKind: String, Decodable, Sendable {
    case primaryResearch = "primary-research", filing, companyReported = "company-reported", press, vendor, seo, academic, regulator
    case dataPanel = "data-panel"
}

public struct Trust: Decodable, Sendable, Equatable {
    public let tier: Tier
    public let numberInQuote: Bool
    public let confidence: Confidence
}

public struct Datum: Decodable, Sendable {
    public enum Scale: String, Decodable, Sendable { case k, M, B }
    public enum Cmp: String, Decodable, Sendable { case gt, lt, approx }
    public enum Basis: String, Decodable, Sendable { case reported, derived, estimate }
    public let v, lo, hi: Double?
    public let unit: Unit
    public let scale: Scale?
    public let cmp: Cmp?
    public let basis: Basis
    public let cite: [String]
    public let asOf, scope, label: String?
    public let trust: Trust

    /// Value in base units (2.1 + B → 2.1e9). Percent stays as written (69 → 69).
    public var multiplier: Double { switch scale { case .k: 1e3; case .M: 1e6; case .B: 1e9; case nil: 1 } }
    public var isRange: Bool { v == nil }
}

/// `Datum | Rich` (EvidenceTable cells, ConflictSplit headline): a string decodes as text, an object as a Datum.
public enum DatumOrText: Decodable, Sendable {
    case datum(Datum), text(String)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) } else { self = .datum(try c.decode(Datum.self)) }
    }
}
/// `Datum | number` (Quadrant split lines).
public enum DatumOrNumber: Decodable, Sendable {
    case datum(Datum), number(Double)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .datum(try c.decode(Datum.self)) }
    }
}

public struct Labelled: Decodable, Sendable { public let label: String; public let value: Datum }
public struct KeyLabel: Decodable, Sendable { public let key: String; public let label: String }

// MARK: - Layout

public struct Answer: QVSProps {
    public enum Verdict: String, Decodable, Sendable { case settled, leaning, contested, inconclusive }
    public let lead: String
    public let verdict: Verdict?
    enum CodingKeys: String, CodingKey, CaseIterable { case lead, verdict }
    public static let propKeys = keys(CodingKeys.self)
}
public struct Group: QVSProps {
    public let title: String
    enum CodingKeys: String, CodingKey, CaseIterable { case title }
    public static let propKeys = keys(CodingKeys.self)
}
public struct Claim: QVSProps {
    public let text: String
    public let confidence: Confidence
    public let reason: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case text, confidence, reason }
    public static let propKeys = keys(CodingKeys.self)
}

// MARK: - Numbers

public struct Stat: QVSProps {
    public let value: Datum
    public let label: String
    public let of, context: Datum?
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case value, label, of, context, caption }
    public static let propKeys = keys(CodingKeys.self)
}
/// `caption` is nil only inside SmallMultiples panels (the panel props omit it).
public struct RangeCompare: QVSProps {
    public struct Row: Decodable, Sendable { public let label: String; public let value: Datum; public let group: String? }
    public struct Axis: Decodable, Sendable { public let min, max: Double?; public let log: Bool? }
    public let measure: String
    public let rows: [Row]
    public let reference: Labelled?
    public let axis: Axis?
    public let caption: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case measure, rows, reference, axis, caption }
    public static let propKeys = keys(CodingKeys.self)
}
public struct BarCompare: QVSProps {
    public enum Sort: String, Decodable, Sendable { case desc, asc, given }
    public struct MixedBasis: Decodable, Sendable { public let asOf, scope: Bool }
    public let measure: String
    public let bars: [Labelled]
    public let sort: Sort?
    public let caption: String?
    public let mixedBasis: MixedBasis
    enum CodingKeys: String, CodingKey, CaseIterable { case measure, bars, sort, caption, mixedBasis }
    public static let propKeys = keys(CodingKeys.self)
}
public struct TrendLine: QVSProps {
    public struct XAxis: Decodable, Sendable {
        public enum Kind: String, Decodable, Sendable { case time, ordinal }
        public let kind: Kind; public let label: String
    }
    public enum X: Decodable, Sendable, Equatable {
        case number(Double), text(String)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
    }
    public struct Point: Decodable, Sendable { public let x: X; public let y: Datum }
    public struct Series: Decodable, Sendable { public let label: String; public let points: [Point] }
    public let measure: String
    public let x: XAxis
    public let series: [Series]
    public let reference: Labelled?
    public let caption: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case measure, x, series, reference, caption }
    public static let propKeys = keys(CodingKeys.self)
}
/// Nested discrimination: the panels' props type depends on the sibling `of`.
public struct SmallMultiples: QVSProps {
    public struct Panel<P: Decodable & Sendable>: Decodable, Sendable { public let title: String; public let props: P }
    public enum Panels: Sendable {
        case trendLine([Panel<TrendLine>]), barCompare([Panel<BarCompare>]), rangeCompare([Panel<RangeCompare>])
        public var count: Int {
            switch self { case .trendLine(let p): p.count; case .barCompare(let p): p.count; case .rangeCompare(let p): p.count }
        }
    }
    public let panels: Panels
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case of, panels, caption }
    public static let propKeys = keys(CodingKeys.self)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caption = try c.decode(String.self, forKey: .caption)
        switch try c.decode(String.self, forKey: .of) {
        case "TrendLine": panels = .trendLine(try c.decode([Panel<TrendLine>].self, forKey: .panels))
        case "BarCompare": panels = .barCompare(try c.decode([Panel<BarCompare>].self, forKey: .panels))
        case "RangeCompare": panels = .rangeCompare(try c.decode([Panel<RangeCompare>].self, forKey: .panels))
        case let other: throw DecodingError.dataCorruptedError(forKey: .of, in: c, debugDescription: "unknown SmallMultiples.of \(other)")
        }
    }
}

// MARK: - Disagreement and trust

public struct TierMix: Decodable, Sendable, Equatable { public let supported, close, unsupported, unresolved: Int }

public struct ConflictSplit: QVSProps {
    public struct Side: Decodable, Sendable {
        public let label: String
        public let headline: DatumOrText
        public let summary: String
        public let sourceKind: SourceKind
        public let tierMix: TierMix
    }
    public struct Leaning: Decodable, Sendable { public let side: Int; public let why: String }
    public let question: String
    public let sides: [Side]
    public let leaning: Leaning?
    public let settle: String?
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case question, sides, leaning, settle, caption }
    public static let propKeys = keys(CodingKeys.self)
}
public struct SourceMix: QVSProps {
    public enum Scope: Decodable, Sendable, Equatable {
        case answer, group, ids([String])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let ids = try? c.decode([String].self) { self = .ids(ids); return }
            switch try c.decode(String.self) {
            case "answer": self = .answer
            case "group": self = .group
            case let s: throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad SourceMix.scope \(s)")
            }
        }
    }
    public enum By: String, Decodable, Sendable { case kind, tier }
    public struct Count: Decodable, Sendable, Equatable { public let key: String; public let n: Int }
    public let scope: Scope
    public let by: By
    public let caption: String?
    public let counts: [Count]
    enum CodingKeys: String, CodingKey, CaseIterable { case scope, by, caption, counts }
    public static let propKeys = keys(CodingKeys.self)
}
public struct EvidenceTable: QVSProps {
    public struct Column: Decodable, Sendable {
        public enum Align: String, Decodable, Sendable { case start, end }
        public let key, label: String; public let align: Align?
    }
    public let columns: [Column]
    public let rows: [[String: DatumOrText]]
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case columns, rows, caption }
    public static let propKeys = keys(CodingKeys.self)
}

// MARK: - Structure

public struct Timeline: QVSProps {
    public enum Axis: String, Decodable, Sendable { case date, ordinal }
    public struct Event: Decodable, Sendable {
        public let at, title: String
        public let detail, kind: String?
        public let cite: [String]
        public let tier: Tier
        public let dateInQuote: Bool?
    }
    public let axis: Axis
    public let events: [Event]
    public let kinds: [KeyLabel]?
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case axis, events, kinds, caption }
    public static let propKeys = keys(CodingKeys.self)
}
public struct DecisionMatrix: QVSProps {
    public struct Criterion: Decodable, Sendable {
        public enum Better: String, Decodable, Sendable { case high, low }
        public let key, label: String; public let better: Better?
    }
    public struct Cell: Decodable, Sendable {
        public let option, criterion: String
        /// -2...2; nil = the run found nothing (render a dashed empty cell, never 0).
        public let rating: Int?
        public let note: String?
        public let cite: [String]
        public let tier: Tier?
    }
    public struct Recommend: Decodable, Sendable { public let option, why: String }
    public let options: [KeyLabel]
    public let criteria: [Criterion]
    public let cells: [Cell]
    public let recommend: Recommend?
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case options, criteria, cells, recommend, caption }
    public static let propKeys = keys(CodingKeys.self)
}
public struct Quadrant: QVSProps {
    public struct Axis: Decodable, Sendable { public let label: String; public let split: DatumOrNumber }
    public struct Point: Decodable, Sendable { public let label: String; public let x, y: Datum }
    public let x, y: Axis
    public let regions: [String]
    public let points: [Point]
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case x, y, regions, points, caption }
    public static let propKeys = keys(CodingKeys.self)
}
public struct ArgumentMap: QVSProps {
    public struct Node: Decodable, Sendable {
        public enum Stance: String, Decodable, Sendable { case supports, contradicts, qualifies }
        public let id, text: String
        public let stance: Stance
        public let cite: [String]
        public let parent: String?
        public let tier: Tier
    }
    public let thesis: String
    public let nodes: [Node]
    public let caption: String
    enum CodingKeys: String, CodingKey, CaseIterable { case thesis, nodes, caption }
    public static let propKeys = keys(CodingKeys.self)
}
