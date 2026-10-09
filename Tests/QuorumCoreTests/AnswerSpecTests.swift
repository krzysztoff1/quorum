import XCTest
@testable import QuorumCore

final class AnswerSpecTests: XCTestCase {

    private static let schema = EngineFixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("schema/run.schema.json")

    private func record(_ name: String) throws -> RunRecord {
        try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: EngineFixtures.url("record/\(name).run.json")))
    }

    private func defs() throws -> [String: [String: Any]] {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.schema)) as? [String: Any])
        return try XCTUnwrap(schema["$defs"] as? [String: [String: Any]])
    }

    private func catalog() throws -> [String: [String: Any]] {
        let options = try XCTUnwrap(defs()["QVSElement"]?["oneOf"] as? [[String: Any]])
        var components: [String: [String: Any]] = [:]
        for option in options {
            let properties = try XCTUnwrap(option["properties"] as? [String: Any])
            let type = try XCTUnwrap((properties["type"] as? [String: Any])?["const"] as? String)
            components[type] = try XCTUnwrap(properties["props"] as? [String: Any])
        }
        return components
    }

    private func keys(_ object: [String: Any]?) -> Set<String> {
        Set(((object?["properties"] as? [String: Any]) ?? [:]).keys)
    }

    func testTheAppKnowsEveryComponentTheCatalogDefinesAndNoOther() throws {
        XCTAssertEqual(Set(try catalog().keys), Set(AnswerElement.knownTypes))
    }

    func testEveryComponentDecodesEveryPropTheCatalogDeclares() throws {
        for (type, props) in try catalog() {
            XCTAssertEqual(keys(props), Set(AnswerElement.wireKeys(of: type)), "\(type) drifted from the catalog — mirror it in AnswerSpec.swift")
        }
    }

    func testDatumsAndTheirTrustMatchTheCatalog() throws {
        let defs = try defs()
        XCTAssertEqual(keys(defs["QVSDatum"]), Set(Datum.CodingKeys.allCases.map(\.rawValue)))
        XCTAssertEqual(keys(defs["QVSTrust"]), Set(DatumTrust.CodingKeys.allCases.map(\.rawValue)))
        XCTAssertEqual(keys(defs["QVSTierMix"]), Set(TierMix.CodingKeys.allCases.map(\.rawValue)))
    }

    func testTheGoldenAnswerDecodesIntoTheComponentsTheEngineWrote() throws {
        let spec = try record("personalization").answer!.spec
        XCTAssertEqual(spec.root, "answer")
        guard case .answer(let root, let groups) = spec.elements["answer"] else { return XCTFail("no answer root") }
        XCTAssertEqual(groups, ["g_roi", "g_vendor", "g_money", "g_risk"])
        XCTAssertTrue(root.lead.hasPrefix("Personalization pays in food tech"))
        guard case .barCompare(let ads) = spec.elements["ads"] else { return XCTFail("ads is not a BarCompare") }
        let doordash = try XCTUnwrap(ads.bars.first { $0.label == "DoorDash" })
        XCTAssertEqual(doordash.value.trust, DatumTrust(tier: .supported, trace: .untraced, confidence: .unverified))
        XCTAssertEqual(ads.mixedBasis, MixedBasis(asOf: true, scope: true))
        guard case .conflictSplit(let split) = spec.elements["split"] else { return XCTFail("split is not a ConflictSplit") }
        XCTAssertEqual(split.leaning?.side, 0)
        XCTAssertEqual(split.sides.map(\.sourceType), [.primary, .seo])
        guard case .sourceMix(let mix) = spec.elements["mix"] else { return XCTFail("mix is not a SourceMix") }
        XCTAssertEqual(mix.counts?.first, SourceCount(key: "primary", n: 3))
    }

    func testTheDowngradedTableAndTheStatDecode() throws {
        let spec = try record("allergy").answer!.spec
        guard case .stat(let stat) = spec.elements["allergy"] else { return XCTFail("allergy is not a Stat") }
        XCTAssertEqual(stat.value.v, 80)
        XCTAssertEqual(stat.of?.v, 50)
        guard case .evidenceTable(let table) = spec.elements["share"] else { return XCTFail("share is not a table") }
        XCTAssertEqual(table.rows.count, 2)
        guard case .datum(let walmart)? = table.rows.first?["value"] else { return XCTFail("the value cell is not a datum") }
        XCTAssertEqual(walmart.v, 25)
    }

    func testAComponentFromANewerEngineDecodesAsUnknownAndRoundTrips() throws {
        let json = #"{"v":1,"root":"a","elements":{"a":{"type":"Answer","props":{"lead":"L[^c1]."},"children":["g"]},"g":{"type":"Group","props":{"title":"T"},"children":["t"]},"t":{"type":"Timeline","props":{"axis":"date","events":[],"caption":"C[^c1]."}}}}"#
        let spec = try JSONDecoder().decode(AnswerSpec.self, from: Data(json.utf8))
        guard case .unknown(let type, _) = spec.elements["t"] else { return XCTFail("a Timeline should decode as unknown") }
        XCTAssertEqual(type, "Timeline")
        let again = try JSONDecoder().decode(AnswerSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(again, spec)
    }

    func testAUnitOrSourceTypeFromANewerEngineDecodesAsUnknown() throws {
        let datum = try JSONDecoder().decode(Datum.self, from: Data(#"{"v":3,"unit":"furlongs","basis":"hunch","cite":["c1"]}"#.utf8))
        XCTAssertEqual(datum.unit, .unknown)
        XCTAssertEqual(datum.basis, .unknown)
    }
}
