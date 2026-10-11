import Foundation

public enum ClaimStrength: String, Sendable, Equatable {
    case solid, shaky, unchecked
}

public enum DatumMark: String, Sendable, Equatable {
    case verified, close, estimate, unverified

    public var legend: String {
        switch self {
        case .verified: return "Quote verified"
        case .close: return "Close match"
        case .estimate: return "The run's estimate"
        case .unverified: return "Not in its quote"
        }
    }
}

public enum FigureDisplay: String, Sendable, Equatable {
    case chart, table
}

public struct FigureValue: Sendable, Equatable {
    public let text: String
    public let low: Double
    public let high: Double
    public let isRange: Bool
    public let cites: [String]
    public let mark: DatumMark
    public let basis: DatumBasis
    public let why: String?
    public let label: String?

    public init(_ datum: Datum) {
        text = DatumFormat.text(datum)
        let multiplier = DatumFormat.multiplier(datum)
        low = (datum.v ?? datum.lo ?? 0) * multiplier
        high = (datum.v ?? datum.hi ?? datum.lo ?? 0) * multiplier
        isRange = datum.v == nil
        cites = datum.cite
        mark = Self.mark(datum)
        basis = datum.basis
        why = Self.why(datum, mark: mark)
        label = datum.label
    }

    public var markedText: String {
        switch mark {
        case .close: return "≈" + text
        case .estimate: return text + " (estimate)"
        default: return text
        }
    }

    public var spoken: String { "\(markedText), \(mark.legend)" }

    static func mark(_ datum: Datum) -> DatumMark {
        guard let trust = datum.trust else { return .unverified }
        if trust.confidence == .unverified { return .unverified }
        if datum.basis == .estimate { return .estimate }
        if trust.tier == .close { return .close }
        return .verified
    }

    static func why(_ datum: Datum, mark: DatumMark) -> String? {
        guard let trust = datum.trust else { return "The engine has not checked this number." }
        switch mark {
        case .verified: return nil
        case .close: return "The quote matched the stored source closely, not exactly."
        case .estimate: return "The run's own estimate, not a quoted figure."
        case .unverified:
            if trust.tier == .unresolved { return "The quote was not found in the stored source." }
            if trust.tier == .unsupported { return "The claim sweep found the quote does not support it." }
            return "The number is not in the quoted passage."
        }
    }
}

public enum DatumFormat {
    public static func multiplier(_ datum: Datum) -> Double {
        if datum.unit == .pct || datum.unit == .pp { return 1 }
        switch datum.scale {
        case .thousand: return 1e3
        case .million: return 1e6
        case .billion: return 1e9
        default: return 1
        }
    }

    public static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 3
        formatter.usesGroupingSeparator = abs(rounded) >= 10_000 || abs(rounded) >= 1000
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    public static func text(_ datum: Datum) -> String {
        let scale = datum.scale.map { $0 == .unknown ? "" : $0.rawValue } ?? ""
        func one(_ value: Double) -> String {
            let n = number(value) + scale
            switch datum.unit {
            case .usd: return "$" + n
            case .eur: return "€" + n
            case .gbp: return "£" + n
            case .pct: return n + "%"
            case .pp: return n + " pp"
            case .ratio: return n + "×"
            default:
                let word = datum.suffix.flatMap { $0.isEmpty ? nil : $0 } ?? unitWord(datum.unit)
                return word.map { "\(n) \($0)" } ?? n
            }
        }
        let body: String
        if let v = datum.v {
            body = one(v)
        } else if datum.unit == .pct {
            body = "\(number(datum.lo ?? 0))–\(number(datum.hi ?? 0))\(scale)%"
        } else {
            body = "\(one(datum.lo ?? 0))–\(one(datum.hi ?? 0))"
        }
        switch datum.cmp {
        case .gt: return ">" + body
        case .lt: return "<" + body
        case .approx: return "~" + body
        default: return body
        }
    }

    private static func unitWord(_ unit: DatumUnit) -> String? {
        switch unit {
        case .days: return "days"
        case .months: return "months"
        case .years: return "years"
        case .items: return "items"
        default: return nil
        }
    }

    public static func sublabel(_ datum: Datum) -> String? {
        let parts = [datum.scope, datum.asOf].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where step * magnitude >= value { return step * magnitude }
        return 10 * magnitude
    }
}

public struct AnswerClaimRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let strength: ClaimStrength
    public let confidence: DatumConfidence
    public let reason: String?
    public let cites: [String]
}

public struct RangeFigureRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let sublabel: String?
    public let group: String?
    public let value: FigureValue
    public let offScale: Bool
}

public struct RangeFigure: Sendable, Equatable {
    public let rows: [RangeFigureRow]
    public let reference: RangeFigureRow?
    public let domain: ClosedRange<Double>
}

public struct BarFigureRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let sublabel: String?
    public let value: FigureValue
    public let offScale: Bool
}

public struct BarFigure: Sendable, Equatable {
    public let bars: [BarFigureRow]
    public let domain: ClosedRange<Double>
    public let notLikeForLike: String?
}

public struct ConflictFigureSide: Sendable, Equatable, Identifiable {
    public let id: Int
    public let label: String
    public let headline: String
    public let headlineValue: FigureValue?
    public let summary: String
    public let sourceType: String
    public let tierMix: TierMix?
}

public struct ConflictFigure: Sendable, Equatable {
    public let question: String
    public let sides: [ConflictFigureSide]
    public let leaning: Int?
    public let why: String?
    public let settle: String?
}

public struct MixSegment: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let n: Int
    public let fraction: Double
}

public struct MixFigure: Sendable, Equatable {
    public let by: String
    public let segments: [MixSegment]
    public let total: Int
    public let summary: String
}

public struct StatPart: Sendable, Equatable {
    public let text: String
    public let label: String?
    public let value: FigureValue
}

public struct StatFigure: Sendable, Equatable {
    public let value: FigureValue
    public let label: String
    public let of: StatPart?
    public let context: StatPart?
    public let share: Double?
}

public struct TableFigureCell: Sendable, Equatable {
    public let text: String
    public let value: FigureValue?
    public let cites: [String]
}

public struct TableFigureRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let cells: [TableFigureCell]
}

public struct TableFigure: Sendable, Equatable {
    public let columns: [TableColumn]
    public let rows: [TableFigureRow]
}

public enum AnswerFigureKind: Sendable, Equatable {
    case stat(StatFigure)
    case range(RangeFigure)
    case bars(BarFigure)
    case conflict(ConflictFigure)
    case mix(MixFigure)
    case table(TableFigure)
    case fallback(type: String)
}

public struct AnswerFigure: Sendable, Equatable, Identifiable {
    public let id: String
    public let measure: String
    public let caption: String
    public let display: FigureDisplay
    public let kind: AnswerFigureKind
    public let fallbackMarkdown: String
    public let cites: [String]

    public var footnotes: [String] {
        switch kind {
        case .bars(let bars): return [bars.notLikeForLike, unverifiedNote(bars.bars.map(\.value))].compactMap { $0 }
        case .range(let range): return [unverifiedNote(range.rows.map(\.value))].compactMap { $0 }
        default: return []
        }
    }

    private func unverifiedNote(_ values: [FigureValue]) -> String? {
        let count = values.filter { $0.mark == .unverified }.count
        guard count > 0 else { return nil }
        if display == .table { return "Most of these numbers are not in their quotes, so they are shown as a table." }
        return "\(count) number\(count == 1 ? " is" : "s are") not in \(count == 1 ? "its" : "their") quote and shown unverified."
    }

    public var togglesTable: Bool {
        switch kind {
        case .range, .bars: return true
        default: return false
        }
    }
}

public enum AnswerItem: Sendable, Equatable, Identifiable {
    case claim(AnswerClaimRow)
    case figure(AnswerFigure)

    public var id: String {
        switch self {
        case .claim(let claim): return claim.id
        case .figure(let figure): return figure.id
        }
    }
}

public struct AnswerSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let items: [AnswerItem]
}

public struct AnswerStrip: Sendable, Equatable {
    public let trustLevel: RecordStatsTrustLevel
    public let claimMarks: [ClaimStrength]
    public let conflictsOpen: Int
    public let objectionsOpen: Int
    public let sourcesCited: Int
    public let sourcesRead: Int
    public let unverifiedNumbers: Int
    public let checkProblems: [String]
}

public struct AnswerOpenItems: Sendable, Equatable {
    public struct Conflict: Sendable, Equatable, Identifiable {
        public let id: String
        public let statement: String
        public let positions: [String]
    }

    public struct Objection: Sendable, Equatable, Identifiable {
        public let id: String
        public let lens: String
        public let statement: String
        public let followup: String
        public let blocking: Bool
    }

    public let conflicts: [Conflict]
    public let objections: [Objection]
    public let gaps: [String]

    public var count: Int { conflicts.count + objections.count + gaps.count }

    init(record: RunRecord) {
        let open = record.openItems
        conflicts = record.conflicts.filter { open.conflicts.contains($0.id) }
            .map { Conflict(id: $0.id, statement: $0.statement, positions: $0.positions) }
        objections = (record.validation?.objectionsOpen ?? []).filter { open.objections.contains($0.id) }
            .map { Objection(id: $0.id, lens: $0.lens.replacingOccurrences(of: "_", with: " "), statement: $0.statement,
                             followup: $0.followup, blocking: $0.severity == .blocking) }
        gaps = record.gaps.filter { open.gaps.contains($0.id) }.map(\.text)
    }
}

public struct AnswerPage: Sendable, Equatable {
    public let runID: String
    public let title: String
    public let question: String
    public let lead: String
    public let verdict: AnswerVerdict?
    public let sections: [AnswerSection]
    public let citationOrder: [String]
    public let strip: AnswerStrip
    public let openItems: AnswerOpenItems
    public let answerNodeID: String?
    private let numbers: [String: Int]

    public func number(of citation: String) -> Int? { numbers[citation] }

    public init?(run: StoredRun) {
        guard let answer = run.record.answer else { return nil }
        let spec = answer.spec
        let record = run.record
        guard case .answer(let root, let groupKeys)? = spec.elements[spec.root] else { return nil }
        let strengths = Self.strengths(record.claims)
        var order: [String] = []
        func cite(_ ids: [String]) { for id in ids where !order.contains(id) { order.append(id) } }
        cite(CitationMarkers.ids(in: root.lead))
        var sections: [AnswerSection] = []
        for key in groupKeys {
            guard case .group(let group, let children)? = spec.elements[key] else { continue }
            var items: [AnswerItem] = []
            for child in children {
                guard let element = spec.elements[child] else { continue }
                if case .claim(let claim) = element {
                    let ids = CitationMarkers.ids(in: claim.text)
                    cite(ids)
                    items.append(.claim(AnswerClaimRow(id: child, text: claim.text, strength: strengths[child] ?? .unchecked,
                                                       confidence: claim.confidence, reason: claim.reason, cites: ids)))
                } else if let figure = Self.figure(child, element, answer: answer) {
                    cite(figure.cites)
                    items.append(.figure(figure))
                }
            }
            sections.append(AnswerSection(id: key, title: group.title, items: items))
        }
        runID = record.id
        title = run.title
        question = record.brief.question
        lead = root.lead
        verdict = root.verdict
        self.sections = sections
        citationOrder = order
        numbers = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0 + 1) })
        answerNodeID = run.answerTask?.nodeID
        openItems = AnswerOpenItems(record: record)
        strip = AnswerStrip(
            trustLevel: record.stats.trustLevel,
            claimMarks: record.claims.map(Self.strength),
            conflictsOpen: record.stats.conflictsOpen,
            objectionsOpen: record.stats.objectionsOpen,
            sourcesCited: record.stats.sourcesCited,
            sourcesRead: record.stats.sourcesRead,
            unverifiedNumbers: record.stats.datumsUnverified,
            checkProblems: record.checks.filter { $0.status == .fail }.map { "\($0.id): \($0.detail)" })
    }

    static func strength(_ claim: RecordClaim) -> ClaimStrength {
        switch claim.verdict.verdict {
        case .unjudged, .unknown: return .unchecked
        case .supported: return claim.strength == .solid ? .solid : .shaky
        default: return .shaky
        }
    }

    static func strengths(_ claims: [RecordClaim]) -> [String: ClaimStrength] {
        var byElement: [String: [ClaimStrength]] = [:]
        for claim in claims { if let id = claim.elementID { byElement[id, default: []].append(strength(claim)) } }
        return byElement.mapValues { marks in
            if marks.contains(.shaky) { return .shaky }
            if marks.contains(.unchecked) { return .unchecked }
            return .solid
        }
    }

    static func figure(_ id: String, _ element: AnswerElement, answer: RecordAnswer) -> AnswerFigure? {
        let display: FigureDisplay = answer.display[id] == .table ? .table : .chart
        let fallback = answer.fallbackMd[id] ?? ""
        func make(_ measure: String, _ caption: String, _ kind: AnswerFigureKind, _ data: [String]) -> AnswerFigure {
            var cites: [String] = []
            for id in CitationMarkers.ids(in: caption) + data where !cites.contains(id) { cites.append(id) }
            return AnswerFigure(id: id, measure: measure, caption: caption, display: display, kind: kind,
                                fallbackMarkdown: fallback, cites: cites)
        }
        switch element {
        case .stat(let props):
            let value = FigureValue(props.value)
            let of = props.of.map { StatPart(text: DatumFormat.text($0), label: $0.label, value: FigureValue($0)) }
            let context = props.context.map { StatPart(text: DatumFormat.text($0), label: $0.label, value: FigureValue($0)) }
            let share: Double? = props.of == nil ? nil
                : props.value.unit == .pct ? (props.value.v ?? 0) / 100
                : props.of?.v.flatMap { $0 > 0 ? (props.value.v ?? 0) / $0 : nil }
            let data = [props.value, props.of, props.context].compactMap { $0 }.flatMap(\.cite)
            return make(props.label, props.caption, .stat(StatFigure(value: value, label: props.label, of: of, context: context, share: share)), data)
        case .rangeCompare(let props):
            let rows = props.rows.enumerated().map { index, row in
                (id: "\(id).\(index)", label: row.label, sublabel: DatumFormat.sublabel(row.value), group: row.group, value: FigureValue(row.value))
            }
            let reference = props.reference.map { (id: "\(id).reference", label: $0.label, sublabel: DatumFormat.sublabel($0.value), group: String?.none, value: FigureValue($0.value)) }
            let all = rows + (reference.map { [$0] } ?? [])
            let axisScale = props.rows.first.map { DatumFormat.multiplier($0.value) } ?? 1
            let lower = props.axis?.min.map { $0 * axisScale } ?? min(0, all.map(\.value.low).min() ?? 0)
            let upper = props.axis?.max.map { $0 * axisScale } ?? DatumFormat.niceCeiling(scaledMaximum(all.map(\.value)))
            func row(_ r: (id: String, label: String, sublabel: String?, group: String?, value: FigureValue)) -> RangeFigureRow {
                RangeFigureRow(id: r.id, label: r.label, sublabel: r.sublabel, group: r.group, value: r.value, offScale: r.value.high > upper)
            }
            let figure = RangeFigure(rows: rows.map(row), reference: reference.map(row), domain: lower...max(upper, lower + 1))
            return make(props.measure, props.caption, .range(figure), all.flatMap(\.value.cites))
        case .barCompare(let props):
            let values = props.bars.map { FigureValue($0.value) }
            let upper = DatumFormat.niceCeiling(scaledMaximum(values))
            let lowest = scaledMinimum(values)
            let lower = lowest < 0 ? -DatumFormat.niceCeiling(-lowest) : 0
            var bars = props.bars.enumerated().map { index, bar in
                let value = values[index]
                return BarFigureRow(id: "\(id).\(index)", label: bar.label, sublabel: DatumFormat.sublabel(bar.value), value: value,
                                    offScale: value.high > upper || value.low < lower)
            }
            switch props.sort ?? "desc" {
            case "asc": bars.sort { $0.value.high < $1.value.high }
            case "given": break
            default: bars.sort { $0.value.high > $1.value.high }
            }
            let figure = BarFigure(bars: bars, domain: lower...upper, notLikeForLike: notLikeForLike(props.mixedBasis))
            return make(props.measure, props.caption, .bars(figure), bars.flatMap(\.value.cites))
        case .conflictSplit(let props):
            let sides = props.sides.enumerated().map { index, side in
                ConflictFigureSide(id: index, label: side.label,
                                   headline: side.headline.datum.map(DatumFormat.text) ?? { if case .text(let t) = side.headline { return t } else { return "" } }(),
                                   headlineValue: side.headline.datum.map(FigureValue.init), summary: side.summary,
                                   sourceType: side.sourceType.rawValue, tierMix: side.tierMix)
            }
            let data = props.sides.flatMap { ($0.headline.datum?.cite ?? []) + CitationMarkers.ids(in: $0.summary) }
                + CitationMarkers.ids(in: props.leaning?.why ?? "")
            let figure = ConflictFigure(question: props.question, sides: sides, leaning: props.leaning?.side,
                                        why: props.leaning?.why, settle: props.settle)
            return make(props.question, props.caption, .conflict(figure), data)
        case .sourceMix(let props):
            let counts = props.counts ?? []
            let total = props.total ?? counts.reduce(0) { $0 + $1.n }
            let segments = counts.map { MixSegment(key: $0.key, n: $0.n, fraction: total > 0 ? Double($0.n) / Double(total) : 0) }
            let figure = MixFigure(by: props.by, segments: segments, total: total, summary: mixSummary(props.by, counts, total))
            return make(props.by == "tier" ? "How the quotes checked out" : "Where the evidence comes from", props.caption ?? "", .mix(figure), [])
        case .evidenceTable(let props):
            let rows = props.rows.enumerated().map { index, row in
                TableFigureRow(id: index, cells: props.columns.map { column in
                    switch row[column.key] {
                    case .datum(let datum)?: return TableFigureCell(text: DatumFormat.text(datum), value: FigureValue(datum), cites: datum.cite)
                    case .text(let text)?: return TableFigureCell(text: text, value: nil, cites: CitationMarkers.ids(in: text))
                    case nil: return TableFigureCell(text: "", value: nil, cites: [])
                    }
                })
            }
            let measure = props.columns.dropFirst().first?.label ?? ""
            return make(measure, props.caption, .table(TableFigure(columns: props.columns, rows: rows)), rows.flatMap { $0.cells.flatMap(\.cites) })
        case .unknown(let type, _):
            return make(type, "", .fallback(type: type), CitationMarkers.ids(in: fallback))
        default:
            return nil
        }
    }

    static func scaledMinimum(_ values: [FigureValue]) -> Double {
        let trusted = values.filter { $0.mark != .unverified }
        return min(0, (trusted.isEmpty ? values : trusted).map(\.low).min() ?? 0)
    }

    static func scaledMaximum(_ values: [FigureValue]) -> Double {
        let trusted = values.filter { $0.mark != .unverified }
        return (trusted.isEmpty ? values : trusted).map(\.high).max() ?? 1
    }

    static func notLikeForLike(_ basis: MixedBasis?) -> String? {
        guard let basis else { return nil }
        switch (basis.asOf, basis.scope) {
        case (true, true): return "Not like-for-like: the bars differ in period and in scope."
        case (true, false): return "Not like-for-like: the bars differ in period."
        case (false, true): return "Not like-for-like: the bars differ in scope."
        default: return nil
        }
    }

    static func mixSummary(_ by: String, _ counts: [SourceCount], _ total: Int) -> String {
        let count = { (keys: Set<String>) in counts.filter { keys.contains($0.key) }.reduce(0) { $0 + $1.n } }
        if by == "tier" { return "\(count(["supported", "close"])) of \(total) quotes verified" }
        return "\(count(["vendor", "seo"])) of \(total) sources are vendor or SEO"
    }
}
