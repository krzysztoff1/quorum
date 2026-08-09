import XCTest
@testable import QuorumCore

/// The routing truth table (PRD 02 R2). Subscription/Benchmark are pure-CLI; Budget splits angles onto
/// the engine and keeps synthesis/verify on the subscription; Full BYOK is all-engine — except any
/// project-context topic, which must always fall back to the CLI because the engine is web-only in v1.
final class RoutingTests: XCTestCase {

    func testSubscriptionIsAllCLI() {
        let p = RunProfile.subscription
        for role in [TopicRole.research, .synthesis, .verify, .plain] {
            XCTAssertEqual(p.executor(for: role, useProjectContext: false), .cli)
        }
        XCTAssertEqual(p.plannerKind, .cli)
        XCTAssertFalse(p.needsEngineKeys)
    }

    func testBenchmarkIsPinnedPureClaude() {
        let p = RunProfile.benchmark
        for role in [TopicRole.research, .synthesis, .verify, .plain] {
            XCTAssertEqual(p.executor(for: role, useProjectContext: false), .cli)
        }
        XCTAssertEqual(p.plannerKind, .cli)
    }

    func testBudgetSplitsAnglesToEngineSynthesisToCLI() {
        let p = RunProfile.budget
        XCTAssertEqual(p.executor(for: .research, useProjectContext: false), .engine)
        XCTAssertEqual(p.executor(for: .synthesis, useProjectContext: false), .cli)
        XCTAssertEqual(p.executor(for: .verify, useProjectContext: false), .cli)
        XCTAssertEqual(p.plannerKind, .engine)
        XCTAssertTrue(p.needsEngineKeys)
    }

    func testFullBYOKIsAllEngine() {
        let p = RunProfile.fullBYOK
        XCTAssertEqual(p.executor(for: .research, useProjectContext: false), .engine)
        XCTAssertEqual(p.executor(for: .synthesis, useProjectContext: false), .engine)
        XCTAssertEqual(p.executor(for: .verify, useProjectContext: false), .engine)
        XCTAssertEqual(p.plannerKind, .engine)
    }

    /// The BYOK engine is web-only in v1, so a topic that must read the working directory falls back to
    /// the CLI. Codex is exempt: its backend opens the project itself (read-only sandbox), so routing it
    /// to the Claude CLI would run a different model than the report names.
    func testProjectContextRoutesToCLIForEveryWebOnlyProfile() {
        for p in RunProfile.allCases where p != .codex {
            XCTAssertEqual(p.executor(for: .research, useProjectContext: true), .cli,
                           "\(p.displayName): engine is web-only, project context must use the CLI")
        }
    }

    func testSubscriptionAlwaysAvailable() {
        XCTAssertTrue(RunProfile.subscription.availability(hasModelKey: false, hasSearchKey: false).ok)
        XCTAssertTrue(RunProfile.benchmark.availability(hasModelKey: false, hasSearchKey: false).ok)
    }

    func testModelProviderParsing() {
        XCTAssertEqual(ModelID.provider("deepseek/deepseek-chat"), "deepseek")
        XCTAssertEqual(ModelID.provider("openrouter/meta-llama/llama-3"), "openrouter")
        XCTAssertEqual(ModelID.provider("claude-code/claude-opus-4-8"), "claude-code")
        XCTAssertTrue(ModelID.isSubscription("claude-code"))
        XCTAssertFalse(ModelID.isSubscription("deepseek/deepseek-chat"))
    }

    func testBudgetNeedsBothKeys() {
        let p = RunProfile.budget
        XCTAssertFalse(p.availability(hasModelKey: false, hasSearchKey: false).ok)
        XCTAssertFalse(p.availability(hasModelKey: true, hasSearchKey: false).ok)
        XCTAssertNotNil(p.availability(hasModelKey: true, hasSearchKey: false).reason)
        XCTAssertFalse(p.availability(hasModelKey: false, hasSearchKey: true).ok)
        XCTAssertTrue(p.availability(hasModelKey: true, hasSearchKey: true).ok)
        XCTAssertNil(p.availability(hasModelKey: true, hasSearchKey: true).reason)
    }
}
