import XCTest
@testable import QuorumCore

final class UsageLedgerTests: XCTestCase {

    func testParsesEngineUsageEvent() {
        let line = #"{"type":"usage","total_cost_usd":0.0031,"usage":{"provider":"deepseek","model":"deepseek-chat","input_tokens":1200,"output_tokens":800,"cache_read_tokens":10,"cache_write_tokens":20,"cost_usd":0.0007,"search_calls":1,"fetch_calls":2}}"#
        let sl = ResearchOutputParser.parseStreamLine(line)
        XCTAssertEqual(sl?.totalCostUSD, Decimal(0.0031))
        let u = sl?.usage
        XCTAssertEqual(u?.provider, "deepseek")
        XCTAssertEqual(u?.model, "deepseek-chat")
        XCTAssertEqual(u?.inputTokens, 1200)
        XCTAssertEqual(u?.outputTokens, 800)
        XCTAssertEqual(u?.cacheReadTokens, 10)
        XCTAssertEqual(u?.cacheWriteTokens, 20)
        XCTAssertEqual(u?.searchCalls, 1)
        XCTAssertEqual(u?.fetchCalls, 2)
        XCTAssertEqual(u?.costUSD, Decimal(0.0007))
    }

    func testParsesCLIModelUsageOnResult() {
        let line = #"{"type":"result","subtype":"success","total_cost_usd":0.5697,"usage":{"input_tokens":1788,"output_tokens":9405,"cache_read_input_tokens":244372,"cache_creation_input_tokens":76822,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0}},"modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":236150,"outputTokens":16623,"cacheReadInputTokens":244372,"cacheCreationInputTokens":76822,"webSearchRequests":13,"costUSD":0.5697}}}"#
        let u = ResearchOutputParser.parseStreamLine(line)?.usage
        XCTAssertEqual(u?.provider, "anthropic")
        XCTAssertEqual(u?.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(u?.inputTokens, 236150)
        XCTAssertEqual(u?.outputTokens, 16623)
        XCTAssertEqual(u?.cacheReadTokens, 244372)
        XCTAssertEqual(u?.cacheWriteTokens, 76822)
        XCTAssertEqual(u?.searchCalls, 13)
        XCTAssertEqual(u?.costUSD, Decimal(0.5697))
    }

    func testCLIPerMessageUsageIgnoredSoNoDoubleCount() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"usage":{"input_tokens":7,"output_tokens":7947}}"#
        XCTAssertNil(ResearchOutputParser.parseStreamLine(line)?.usage)
    }

    func testAccumulateSumsEngineSteps() {
        let steps = [
            ResearchOutputParser.StepUsage(provider: "deepseek", model: "deepseek-chat", inputTokens: 100,
                      outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0, searchCalls: 1, fetchCalls: 0,
                      costUSD: Decimal(string: "0.001")),
            ResearchOutputParser.StepUsage(provider: "deepseek", model: "deepseek-chat", inputTokens: 200,
                      outputTokens: 80, cacheReadTokens: 5, cacheWriteTokens: 0, searchCalls: 0, fetchCalls: 2,
                      costUSD: Decimal(string: "0.002")),
        ]
        let t = TopicUsage.from(steps: steps)
        XCTAssertEqual(t?.provider, "deepseek")
        XCTAssertEqual(t?.model, "deepseek-chat")
        XCTAssertEqual(t?.inputTokens, 300)
        XCTAssertEqual(t?.outputTokens, 130)
        XCTAssertEqual(t?.cacheReadTokens, 5)
        XCTAssertEqual(t?.searchCalls, 1)
        XCTAssertEqual(t?.fetchCalls, 2)
        XCTAssertEqual(t?.costUSD, Decimal(string: "0.003"))
    }

    func testAccumulateEmptyIsNil() {
        XCTAssertNil(TopicUsage.from(steps: []))
    }

    func testDigestRendersUsageLedger() {
        let usage = TopicUsage(provider: "deepseek", model: "deepseek-chat", inputTokens: 300,
                               outputTokens: 130, cacheReadTokens: 5, cacheWriteTokens: 0,
                               searchCalls: 3, fetchCalls: 2, costUSD: Decimal(string: "0.03")!)
        let entry = RunReport.TopicEntry(
            id: "1", question: "Q", status: .complete, preset: .standard, headline: "H",
            confidenceSummary: "1 high", sourcesConsulted: 5, costUSD: Decimal(string: "0.03")!,
            durationSeconds: 12, note: nil, notePath: nil, transcriptPath: nil, usage: usage)
        let report = RunReport(startedAt: Date(), finishedAt: Date().addingTimeInterval(12),
                               entries: [entry], totalCostUSD: Decimal(string: "0.03")!, runSpendCapUSD: 40)
        let md = Reporter.renderDigest(report)
        XCTAssertTrue(md.contains("Cost ledger"))
        XCTAssertTrue(md.contains("deepseek-chat"))
        XCTAssertTrue(md.contains("300"))
    }

    /// PRD 06 R7 — validators never appear as topics, so their spend would vanish from the ledger unless
    /// it is carried on its own. A run has to be able to answer "what did checking the answer cost?".
    func testDigestShowsWhatJudgingTheAnswerCost() {
        let usage = TopicUsage(provider: "deepseek", model: "deepseek-chat", inputTokens: 300,
                               outputTokens: 130, cacheReadTokens: 5, cacheWriteTokens: 0,
                               searchCalls: 3, fetchCalls: 2, costUSD: Decimal(string: "0.30")!)
        let entry = RunReport.TopicEntry(
            id: "1", question: "Q", status: .complete, preset: .standard, headline: "H",
            confidenceSummary: "1 high", sourcesConsulted: 5, costUSD: Decimal(string: "0.30")!,
            durationSeconds: 12, note: nil, notePath: nil, transcriptPath: nil, usage: usage)
        let report = RunReport(startedAt: Date(), finishedAt: Date(), entries: [entry],
                               totalCostUSD: Decimal(string: "0.38")!, runSpendCapUSD: 40,
                               validationCostUSD: Decimal(string: "0.08")!)
        let md = Reporter.renderDigest(report)

        XCTAssertTrue(md.contains("validation"), "validation spend is its own line, not folded into a topic")
        XCTAssertTrue(md.contains("$0.08"))
        XCTAssertTrue(md.contains("$0.38"), "the ledger totals what the run actually spent")
    }

    func testAReportWithNoValidationShowsNoValidationRow() {
        let report = RunReport(startedAt: Date(), finishedAt: Date(), entries: [entry(provider: "deepseek")],
                               totalCostUSD: Decimal(string: "0.2")!, runSpendCapUSD: 40)

        XCTAssertNil(report.validationCostUSD)
        XCTAssertFalse(Reporter.renderDigest(report).contains("validation"))
    }

    private func entry(provider: String?, id: String = "1") -> RunReport.TopicEntry {
        let usage = provider.map {
            TopicUsage(provider: $0, model: "m", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                       cacheWriteTokens: 0, searchCalls: 0, fetchCalls: 0, costUSD: Decimal(string: "0.2")!)
        }
        return RunReport.TopicEntry(id: id, question: "Q", status: .complete, preset: .standard, headline: "H",
                                    confidenceSummary: "—", sourcesConsulted: 0, costUSD: Decimal(string: "0.2")!,
                                    durationSeconds: 1, note: nil, notePath: nil, transcriptPath: nil, usage: usage)
    }

    func testWasEngineRunFlagsNonAnthropicProviders() {
        XCTAssertTrue(entry(provider: "deepseek").wasEngineRun)
        XCTAssertFalse(entry(provider: "anthropic").wasEngineRun)
        XCTAssertFalse(entry(provider: nil).wasEngineRun)   // legacy runs with no ledger
    }

    func testEngineCostSumsOnlyEngineTopics() {
        let report = RunReport(startedAt: Date(), finishedAt: Date(),
                               entries: [entry(provider: "deepseek", id: "1"), entry(provider: "anthropic", id: "2")],
                               totalCostUSD: Decimal(string: "0.4")!, runSpendCapUSD: 40)
        XCTAssertEqual(report.engineCostUSD, Decimal(string: "0.2")!)   // only the deepseek topic
    }

    func testDigestStampsProfileAndEngineSpend() {
        let usage = TopicUsage(provider: "deepseek", model: "deepseek-chat", inputTokens: 1, outputTokens: 1,
                               cacheReadTokens: 0, cacheWriteTokens: 0, searchCalls: 1, fetchCalls: 0,
                               costUSD: Decimal(string: "0.2")!)
        let e = RunReport.TopicEntry(id: "1", question: "Q", status: .complete, preset: .standard, headline: "H",
                                     confidenceSummary: "—", sourcesConsulted: 1, costUSD: Decimal(string: "0.2")!,
                                     durationSeconds: 1, note: nil, notePath: nil, transcriptPath: nil, usage: usage)
        let report = RunReport(startedAt: Date(), finishedAt: Date(), entries: [e],
                               totalCostUSD: Decimal(string: "0.2")!, runSpendCapUSD: 40, profile: .budget)
        let md = Reporter.renderDigest(report)
        XCTAssertTrue(md.contains("Profile:"))
        XCTAssertTrue(md.contains("Budget"))
        XCTAssertTrue(md.contains("Engine spend:"))
    }

    func testOldReportJSONWithoutLedgerStillDecodes() throws {
        // A pre-ledger report.json (no `profile`, no per-entry `usage`) must still decode — the new
        // fields are optional. This is the "old runs keep opening" guarantee (PRD 02 R3/R5).
        let json = """
        {"startedAt":700000000,"finishedAt":700000010,"totalCostUSD":1.5,"runSpendCapUSD":40,
         "entries":[{"id":"1","question":"Q","status":"complete","preset":"standard","headline":"H",
         "confidenceSummary":"1 high","sourcesConsulted":2,"costUSD":1.5,"durationSeconds":10,
         "note":null,"notePath":null,"transcriptPath":null}]}
        """
        let report = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertNil(report.profile)
        XCTAssertNil(report.entries.first?.usage)
        XCTAssertFalse(report.entries.first!.wasEngineRun)
        XCTAssertEqual(report.entries.first?.headline, "H")
        XCTAssertEqual(Reporter.renderDigest(report).contains("Cost ledger"), false)  // no ledger without usage
    }

    func testReportWithUsageRoundTripsThroughJSON() throws {
        let usage = TopicUsage(provider: "anthropic", model: "claude-haiku-4-5", inputTokens: 10,
                               outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0,
                               searchCalls: 1, fetchCalls: 0, costUSD: Decimal(string: "0.5")!)
        let entry = RunReport.TopicEntry(
            id: "1", question: "Q", status: .complete, preset: .standard, headline: "H",
            confidenceSummary: "—", sourcesConsulted: 1, costUSD: Decimal(string: "0.5")!,
            durationSeconds: 1, note: nil, notePath: nil, transcriptPath: nil, usage: usage)
        let report = RunReport(startedAt: Date(), finishedAt: Date(), entries: [entry],
                               totalCostUSD: Decimal(string: "0.5")!, runSpendCapUSD: 40)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RunReport.self, from: data)
        XCTAssertEqual(decoded.entries.first?.usage?.model, "claude-haiku-4-5")
        XCTAssertEqual(decoded.entries.first?.usage?.inputTokens, 10)
    }
}
