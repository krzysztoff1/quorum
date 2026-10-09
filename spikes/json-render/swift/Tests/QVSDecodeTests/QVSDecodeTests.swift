import Foundation
import Testing
@testable import QVSDecode

private let spikeDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private func load(_ path: String) throws -> Data { try Data(contentsOf: spikeDir.appendingPathComponent(path)) }

@Suite struct DecodeFixtures {
    @Test func personalization() throws {
        let spec = try QVSSpec.decode(try load("fixtures/personalization.resolved.json"))
        #expect(spec.elements.count == 18)
        guard case .answer(let a)? = spec.rootElement?.body else { Issue.record("root is not an Answer"); return }
        #expect(a.verdict == .leaning)
        #expect(spec.rootElement?.children == ["g_roi", "g_money", "g_how", "g_risk"])

        let counts = Dictionary(grouping: spec.elements.values, by: \.type).mapValues(\.count)
        #expect(counts == ["Answer": 1, "Group": 4, "Claim": 5, "RangeCompare": 1, "ConflictSplit": 1, "BarCompare": 1,
                           "TrendLine": 1, "DecisionMatrix": 1, "Stat": 1, "Timeline": 1, "SourceMix": 1])

        guard case .barCompare(let ads)? = spec.elements["ads"]?.body else { Issue.record("ads"); return }
        #expect(ads.bars.map(\.label) == ["Uber", "Instacart", "DoorDash"])
        #expect(ads.bars[0].value.v == 2 && ads.bars[0].value.scale == .B && ads.bars[0].value.cmp == .gt)
        #expect(ads.bars[2].value.trust == Trust(tier: .unsupported, numberInQuote: false, confidence: .unverified))
        #expect(ads.mixedBasis.asOf && ads.mixedBasis.scope)

        guard case .trendLine(let t)? = spec.elements["retention"]?.body else { Issue.record("retention"); return }
        #expect(t.series[0].points.map(\.y.v) == [69, 36, 28])
        #expect(t.series[0].points.map(\.x) == [.number(1), .number(6), .number(12)])

        guard case .conflictSplit(let split)? = spec.elements["split"]?.body else { Issue.record("split"); return }
        guard case .datum(let starbucks) = split.sides[1].headline else { Issue.record("headline"); return }
        #expect(starbucks.v == 2.1 && starbucks.trust.tier == .close)
        #expect(split.sides[1].tierMix == TierMix(supported: 1, close: 1, unsupported: 0, unresolved: 0))
        #expect(split.sides[1].sourceKind == .seo)

        guard case .decisionMatrix(let m)? = spec.elements["matrix"]?.body else { Issue.record("matrix"); return }
        #expect(m.cells.count == 16)
        #expect(m.cells.filter { $0.rating == nil }.count == 4)

        guard case .sourceMix(let mix)? = spec.elements["mix"]?.body else { Issue.record("mix"); return }
        #expect(mix.scope == .answer && mix.by == .kind)
        #expect(mix.counts.first == SourceMix.Count(key: "company-reported", n: 6))

        guard case .claim(let mem)? = spec.elements["c_memory"]?.body else { Issue.record("c_memory"); return }
        #expect(mem.confidence == .unverified)
    }

    @Test(arguments: ["personalization", "kitchen-sink", "inconclusive"])
    func everyResolvedFixtureDecodes(_ name: String) throws {
        let spec = try QVSSpec.decode(try load("fixtures/\(name).resolved.json"))
        #expect(spec.v == 1)
        for (key, el) in spec.elements {
            if case .unknown(let t) = el.body { Issue.record("\(key) decoded as unknown type \(t)") }
            for c in el.children { #expect(spec.elements[c] != nil, "dangling child \(c)") }
        }
    }

    @Test func kitchenSinkUnions() throws {
        let spec = try QVSSpec.decode(try load("fixtures/kitchen-sink.resolved.json"))
        guard case .smallMultiples(let sm)? = spec.elements["sm"]?.body,
              case .rangeCompare(let panels) = sm.panels else { Issue.record("sm"); return }
        #expect(panels.count == 2 && panels[0].props.caption == nil && panels[0].props.rows[1].value.hi == 2)
        guard case .evidenceTable(let table)? = spec.elements["table"]?.body else { Issue.record("table"); return }
        guard case .text(let who)? = table.rows[0]["who"], case .datum(let lift)? = table.rows[0]["value"] else { Issue.record("cells"); return }
        #expect(who == "Delivery Hero" && lift.v == 85)
        guard case .quadrant(let q)? = spec.elements["quad"]?.body,
              case .number(let xs) = q.x.split, case .datum(let ys) = q.y.split else { Issue.record("quad"); return }
        #expect(xs == 15 && ys.basis == .derived && q.regions.count == 4)
        guard case .argumentMap(let am)? = spec.elements["argmap"]?.body else { Issue.record("argmap"); return }
        #expect(am.nodes.first { $0.id == "n2" }?.tier == .close)
    }

    @Test func unknownTypeDegradesInsteadOfThrowing() throws {
        let json = #"{"v":1,"root":"a","elements":{"a":{"type":"Answer","props":{"lead":"x"},"children":["p"]},"p":{"type":"PieChart","props":{}}}}"#
        let spec = try QVSSpec.decode(Data(json.utf8))
        #expect(spec.elements["p"]?.type == "PieChart")
    }
}

/// Drift detector: the JSON Schema emitted from the Zod catalog is the contract. Every component `type` and every
/// top-level prop it declares must be known to this hand-written mirror (and vice versa).
@Suite struct SchemaDrift {
    let schema: [String: Any]
    init() throws { schema = try JSONSerialization.jsonObject(with: try load("schema/qvs-resolved.schema.json")) as! [String: Any] }

    var components: [String: Set<String>] {
        let defs = schema["$defs"] as! [String: Any]
        let options = (defs["ElementResolved"] as! [String: Any])["oneOf"] as! [[String: Any]]
        var out: [String: Set<String>] = [:]
        for o in options {
            let props = o["properties"] as! [String: Any]
            let type = (props["type"] as! [String: Any])["const"] as! String
            let p = props["props"] as! [String: Any]
            // SmallMultiples props are themselves a oneOf (discriminated on `of`): take the union of keys
            let variants = (p["oneOf"] as? [[String: Any]]) ?? [p]
            out[type] = variants.reduce(into: Set<String>()) { $0.formUnion(($1["properties"] as! [String: Any]).keys) }
        }
        return out
    }

    @Test func everySchemaTypeIsKnown() {
        #expect(Set(components.keys) == Set(QVSElement.known.keys))
    }

    @Test func everyPropIsKnown() {
        for (type, keys) in components {
            #expect(keys == Set(QVSElement.known[type] ?? []), "props drift in \(type)")
        }
    }
}
