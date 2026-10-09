import XCTest
@testable import QuorumCore

final class RunRecordDriftTests: XCTestCase {

    private static let repo = EngineFixtures.directory.deletingLastPathComponent().deletingLastPathComponent()
    private static let schema = repo.appendingPathComponent("schema/run.schema.json")
    private static let questionSchema = repo.appendingPathComponent("schema/question.schema.json")
    private static let generated = repo.appendingPathComponent("Sources/QuorumCore/RunRecord.generated.swift")

    private func recordFixtures() throws -> [URL] {
        let dir = EngineFixtures.url("record")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".run.json") }
        XCTAssertFalse(names.isEmpty, "the engine records golden run records in engine/fixtures/record")
        return names.sorted().map { dir.appendingPathComponent($0) }
    }

    func testEveryRecordTheEngineWroteDecodesThroughTheGeneratedTypes() throws {
        for url in try recordFixtures() {
            XCTAssertNoThrow(try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: url)), url.lastPathComponent)
        }
    }

    func testDecodingAndEncodingARecordKeepsEveryFieldTheEngineWrote() throws {
        for url in try recordFixtures() {
            let data = try Data(contentsOf: url)
            let original = try JSONSerialization.jsonObject(with: data)
            let reencoded = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(JSONDecoder().decode(RunRecord.self, from: data)))
            XCTAssertEqual(keyPaths(original), keyPaths(reencoded), url.lastPathComponent)
        }
    }

    func testTheGeneratedTypesNameEveryPropertyTheSchemaDeclares() throws {
        let swift = try String(contentsOf: Self.generated, encoding: .utf8)
        for url in [Self.schema, Self.questionSchema] {
            let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let defs = (schema["$defs"] as? [String: [String: Any]]) ?? [:]
            let objects = [(schema["title"] as? String ?? "", schema)] + defs.map { ($0.key, $0.value) }
            for (name, object) in objects {
                XCTAssertTrue(swift.contains("public struct \(name): Codable"), "the Swift types lack \(name)")
                for property in ((object["properties"] as? [String: Any]) ?? [:]).keys {
                    XCTAssertTrue(swift.contains("= \"\(property)\"") || swift.contains("case \(property)\n")
                                  || swift.contains("case `\(property)`\n"),
                                  "the Swift types never decode \(name).\(property) — run `bun run schema`")
                }
            }
        }
    }

    func testAnEnumValueAFutureEngineAddsDecodesAsUnknownInsteadOfFailingTheRecord() throws {
        let url = try XCTUnwrap(recordFixtures().first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["status"] = "paused_for_lunch"
        let record = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(record.status, .unknown)
    }

    func testTheStatsTheEngineStoredAgreeWithTheArraysTheAppReads() throws {
        for url in try recordFixtures() {
            let record = try JSONDecoder().decode(RunRecord.self, from: Data(contentsOf: url))
            XCTAssertEqual(record.stats.sourcesCited, record.sources.filter(\.cited).count, url.lastPathComponent)
            XCTAssertEqual(record.stats.claims, record.claims.count)
            XCTAssertEqual(record.stats.claimsSolid, record.claims.filter { $0.strength == .solid }.count)
            XCTAssertEqual(record.stats.conflictsOpen, record.openItems.conflicts.count)
            XCTAssertEqual(record.stats.objectionsOpen, record.validation?.objectionsOpen.count ?? 0)
        }
    }

    private func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        if let object = value as? [String: Any] {
            return object.filter { !($0.value is NSNull) }.reduce(into: Set<String>()) { paths, entry in
                let path = prefix + "." + entry.key
                paths.insert(path)
                paths.formUnion(keyPaths(entry.value, prefix: path))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, prefix: prefix + "[]")) }
        }
        return []
    }
}
