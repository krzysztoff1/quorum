import XCTest
@testable import QuorumCore

/// The Codex profile: a second subscription runner (OpenAI's `codex` CLI, OAuth, no API key) addressed
/// through the TS engine as `codex/<alias>`. It spends no BYOK key and no metered dollars — only the
/// user's Codex limits — so it must never be gated behind provider/search keys, and never be mistaken
/// for the Claude subscription whose sessions the app knows how to resume.
final class CodexRoutingTests: XCTestCase {

    func testCodexModelsAddressTheEngineByAlias() {
        XCTAssertEqual(CodexModel.luna.engineAddress, "codex/luna")
        XCTAssertEqual(CodexModel.terra.engineAddress, "codex/terra")
        XCTAssertEqual(CodexModel.sol.engineAddress, "codex/sol")
        XCTAssertEqual(CodexModel.allCases, [.luna, .terra, .sol])
        XCTAssertEqual(CodexModel.default, .terra)
    }

    func testCodexIsASubscriptionNotABYOKProvider() {
        XCTAssertEqual(ModelID.provider("codex/sol"), "codex")
        XCTAssertTrue(ModelID.isSubscription("codex"))
        XCTAssertTrue(ModelID.isSubscription("codex/luna"))
        XCTAssertTrue(ModelID.isSubscription("claude-code"))
        XCTAssertFalse(ModelID.isSubscription("deepseek/deepseek-chat"))
    }

    func testCodexProfileNeedsNoKeysButDoesNeedTheCLI() {
        let p = RunProfile.codex
        XCTAssertFalse(p.needsEngineKeys)
        XCTAssertTrue(p.availability(hasModelKey: false, hasSearchKey: false, hasCodexCLI: true).ok)
        let missing = p.availability(hasModelKey: true, hasSearchKey: true, hasCodexCLI: false)
        XCTAssertFalse(missing.ok)
        XCTAssertNotNil(missing.reason)
    }

    func testCodexCLIAbsenceOnlyBlocksTheCodexProfile() {
        for p in RunProfile.allCases where p != .codex {
            XCTAssertEqual(p.availability(hasModelKey: true, hasSearchKey: true, hasCodexCLI: false).ok,
                           p.availability(hasModelKey: true, hasSearchKey: true, hasCodexCLI: true).ok,
                           "\(p.displayName) does not run on codex and must not care whether it is installed")
        }
    }

    func testCodexRunsEveryRoleOnTheEngineIncludingProjectContext() {
        let p = RunProfile.codex
        for role in [TopicRole.research, .synthesis, .verify, .plain] {
            XCTAssertEqual(p.executor(for: role, useProjectContext: false), .engine)
        }
        // Unlike the BYOK engine, the codex backend reads the working directory (read-only sandbox),
        // so a project-context topic must NOT be silently handed to the Claude CLI.
        XCTAssertEqual(p.executor(for: .research, useProjectContext: true), .engine)
        XCTAssertEqual(p.plannerKind, .engine)
    }

    func testEveryQuorumEffortLevelSurvivesTheTripToCodex() {
        XCTAssertEqual(Effort.allCases.map(\.rawValue), ["low", "medium", "high", "xhigh", "max"])
    }

    func testACodexTopicIsNotResumableAsAClaudeSession() {
        let line = """
        {"type":"topic_result","angle_id":"a1","role":"research","backend":"codex","provider":"codex",\
        "model":"gpt-5.6-terra","session_id":"019fe6d6","status":"complete","result":"x",\
        "usage":{"provider":"codex","model":"gpt-5.6-terra","input_tokens":10,"output_tokens":2,\
        "cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0,"search_calls":1,"fetch_calls":0}}
        """
        guard case .topicResult(let topic)? = RunStreamParser.parse(line) else {
            return XCTFail("no topic result parsed")
        }
        XCTAssertEqual(topic.backend, "codex")
        XCTAssertFalse(topic.isResumable)
        XCTAssertEqual(topic.usage?.costUSD, 0)
    }
}
