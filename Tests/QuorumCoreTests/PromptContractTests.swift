import XCTest
@testable import QuorumCore

/// Pins the research contract both executors share to `Fixtures/prompt-contract.json`, which the
/// engine's `prompts.test.ts` asserts against the TS prompts — so the Swift orchestrator (the
/// benchmark path) and the TS `run` pipeline (the shipped path) cannot drift apart silently.
final class PromptContractTests: XCTestCase {

    private struct Contract: Decodable {
        let research: [String]
        let synthesis: [String]
        let verify: [String]
        let synthesisContext: [String]
        let templates: [String: String]
        let wordBudget: [String: Int]
    }

    private func contract() throws -> Contract {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/prompt-contract.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    private func topic(_ role: TopicRole) -> PreparedTopic {
        let cfg = GuardrailMapper.runConfig(preset: .standard, perTopicSpendCap: Decimal(string: "1")!,
                                            perTopicTimeout: .seconds(600), depthOverride: nil)
        return PreparedTopic(id: "t1", question: "Q", context: role == .research ? nil : "ctx",
                             projectURL: URL(fileURLWithPath: "/tmp/brain"), useProjectContext: false,
                             preset: .standard, runConfig: cfg, role: role)
    }

    func testResearchSystemPromptCarriesTheContractFragments() throws {
        let prompt = ResearchPrompts.system(for: topic(.research))
        for fragment in try contract().research {
            XCTAssertTrue(prompt.contains(fragment), "research prompt lost: \(fragment)")
        }
    }

    func testSynthesisSystemPromptCarriesTheContractFragments() throws {
        let prompt = ResearchPrompts.synthesisSystem()
        for fragment in try contract().synthesis {
            XCTAssertTrue(prompt.contains(fragment), "synthesis prompt lost: \(fragment)")
        }
    }

    func testVerifySystemPromptCarriesTheContractFragments() throws {
        let prompt = ResearchPrompts.verifySystem()
        for fragment in try contract().verify {
            XCTAssertTrue(prompt.contains(fragment), "verify prompt lost: \(fragment)")
        }
    }

    func testSynthesisContextCarriesTheContractFragments() throws {
        func angle(_ id: String) -> TopicFindings {
            TopicFindings(id: id, status: .complete, preset: .standard, headline: "H",
                          findings: [Finding(claim: "c", sources: ["https://shared.example/paper"], confidence: .high)],
                          sourcesConsulted: 1, costUSD: 0, duration: .seconds(0),
                          writeupMarkdown: "body", transcript: "", note: nil)
        }
        let ctx = synthesisContext(question: "Q", angles: [angle("a1"), angle("a2")])
        for fragment in try contract().synthesisContext {
            XCTAssertTrue(ctx.contains(fragment), "synthesis context lost: \(fragment)")
        }
    }

    func testTemplateInstructionsCarryTheContractFragments() throws {
        for (name, fragment) in try contract().templates {
            let template = try XCTUnwrap(ResearchTemplate(rawValue: name))
            XCTAssertTrue(template.synthesisInstructions.contains(fragment),
                          "template \(name) lost: \(fragment)")
        }
        XCTAssertEqual(ResearchTemplate.general.synthesisInstructions, "")
    }

    func testWordBudgetMatchesTheSharedFormula() throws {
        for (count, budget) in try contract().wordBudget {
            XCTAssertEqual(ResearchPrompts.synthesisWordBudget(angleCount: Int(count)!), budget)
        }
    }
}
