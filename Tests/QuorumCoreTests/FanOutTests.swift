import XCTest
@testable import QuorumCore

/// The fan-out contract: plan N angles → research them BLIND and in parallel → one summariser that
/// sees all → one durable note. All offline via the fakes, deterministic, no spend.
final class FanOutTests: XCTestCase {

    private func angles(_ n: Int) -> [ResearchAngle] {
        (1...n).map { ResearchAngle(id: "angle-\($0)", title: "T\($0)", prompt: "angle prompt \($0)") }
    }

    private func brainNoteFiles(in project: URL) -> [URL] {
        let notes = project.appendingPathComponent("Quorum/notes")
        return ((try? FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
    }

    // MARK: planning

    func testPlanAnglesReturnsRequestedCount() async throws {
        let project = try makeTempProject()
        let planner = FakeAnglePlanner(angles(5))
        let result = try await planAngles(question: "How does X work?", count: 5,
                                          config: standardRun(project: project), planner: planner,
                                          store: DiskFindingsStore(), clock: TestClock(now: fixedStart))
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(planner.calls, 1)
    }

    // MARK: fan-out + synthesis

    func testFanOutRunsAllAnglesThenSynthesizesOneNote() async throws {
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        let store = DiskFindingsStore()
        let report = await runFanOut(question: "How does X work?", angles: angles(5),
                                     config: standardRun(project: project), executor: exec,
                                     clock: TestClock(now: fixedStart), store: store,
                                     power: SpyPower(), notifier: SpyNotifier())

        XCTAssertEqual(exec.researchTopics.count, 5, "all five angles ran (parallel fan-out)")
        XCTAssertNotNil(exec.synthesisTopic, "exactly one summariser ran")
        XCTAssertEqual(report.entries.count, 6, "1 synthesis + 5 angle entries")

        let synth = report.entries[0]
        XCTAssertNotNil(synth.notePath)
        XCTAssertEqual(synth.isSynthesis, true, "first entry is flagged as the synthesis")
        XCTAssertEqual(synth.noteAction, .created, "brand-new question → one created note")
        XCTAssertEqual(brainNoteFiles(in: project).count, 1, "one durable note, not five")

        // Each angle entry points at its writeup artifact, so it opens as a readable note (not just chat).
        let angleEntries = Array(report.entries.dropFirst())
        XCTAssertTrue(angleEntries.allSatisfy { $0.notePath != nil }, "angles are openable")
        XCTAssertTrue(angleEntries.allSatisfy { $0.isSynthesis != true })

        // Five angle writeups saved as run artifacts, each with its own transcript beside it.
        let runDir = store.listRuns(projectURL: project).first!
        let angleFiles = ((try? FileManager.default.contentsOfDirectory(at: runDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.contains("-angle-") }
        XCTAssertEqual(angleFiles.filter { !$0.lastPathComponent.hasSuffix(".transcript.md") }.count, 5)
        XCTAssertEqual(angleFiles.filter { $0.lastPathComponent.hasSuffix(".transcript.md") }.count, 5)
    }

    func testAnglesAreBlindToEachOtherButSynthesisSeesAll() async throws {
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())

        // Isolation: each angle's prompt/context contains ONLY its own prompt, never a sibling's.
        let research = exec.researchTopics
        for t in research {
            for other in research where other.id != t.id {
                XCTAssertFalse(t.question.contains(other.question), "\(t.id) leaked sibling \(other.id)")
                XCTAssertFalse((t.context ?? "").contains(other.question), "\(t.id) ctx leaked \(other.id)")
            }
        }
        // The summariser DID see every angle's writeup.
        let ctx = exec.synthesisTopic?.context ?? ""
        for t in research { XCTAssertTrue(ctx.contains(t.question), "synthesis missing \(t.id)") }
    }

    func testCompoundingMergesSecondFanOutIntoExistingNote() async throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        func once(at t: TimeInterval) async -> RunReport {
            await runFanOut(question: "How does Postgres indexing work?", angles: angles(3),
                            config: standardRun(project: project), executor: RecordingExecutor(),
                            clock: TestClock(now: fixedStart.addingTimeInterval(t)), store: store,
                            power: SpyPower(), notifier: SpyNotifier())
        }
        let first = await once(at: 0)
        XCTAssertEqual(first.entries[0].noteAction, .created)
        let second = await once(at: 86_400)
        XCTAssertEqual(second.entries[0].noteAction, .merged, "same question → reconcile into the note")
        XCTAssertEqual(brainNoteFiles(in: project).count, 1, "deepened into ONE note, not duplicated")
    }

    // MARK: research templates (item 8 — a preset that shapes the synthesis deliverable)

    func testTemplateShapesSynthesisPromptButDefaultDoesNot() async throws {
        let project = try makeTempProject()

        // A template's deliverable instructions reach ONLY the summariser, not the blind angles.
        var matrix = standardRun(project: project); matrix.synthesisTemplate = .comparisonMatrix
        let e1 = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: matrix, executor: e1,
                            clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        XCTAssertTrue((e1.synthesisTopic?.context ?? "").contains("COMPARISON MATRIX"),
                      "synthesis is steered toward the chosen deliverable")
        XCTAssertTrue(e1.researchTopics.allSatisfy { !($0.context ?? "").contains("COMPARISON MATRIX") },
                      "the template shapes synthesis only — angles are unaffected (same engine)")

        // Default (nil template) → no deliverable shaping injected.
        let e2 = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: e2, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        let ctx = e2.synthesisTopic?.context ?? ""
        XCTAssertFalse(ctx.contains("COMPARISON MATRIX"))
        XCTAssertFalse(ctx.contains("DECISION BRIEF"))
        XCTAssertFalse(ctx.contains("LITERATURE REVIEW"))
    }

    // MARK: per-angle budget (planner marks cheap angles shallow → they run at the draft preset)

    func testShallowAngleRunsAtDraftBudget() async throws {
        // A planner-marked shallow angle runs at the draft preset while its unmarked siblings keep the run
        // default — per-angle budget, so a cheap lookup genuinely runs cheaper (fewer sources, less effort).
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        let mixed = [ResearchAngle(id: "shallow", title: "S", prompt: "a simple lookup", preset: .draft),
                     ResearchAngle(id: "deep", title: "D", prompt: "a real investigation")]
        _ = await runFanOut(question: "Q", angles: mixed, config: standardRun(project: project),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        let shallow = try XCTUnwrap(exec.researchTopics.first { $0.id == "shallow" })
        let deep = try XCTUnwrap(exec.researchTopics.first { $0.id == "deep" })
        XCTAssertEqual(shallow.preset, .draft)
        XCTAssertEqual(shallow.runConfig.sourceBudget, GuardrailMapper.spec(for: .draft).sourceBudget)
        XCTAssertEqual(deep.preset, .standard, "an unmarked angle inherits the run default")
        XCTAssertEqual(deep.runConfig.sourceBudget, GuardrailMapper.spec(for: .standard).sourceBudget)
        XCTAssertLessThan(shallow.runConfig.sourceBudget, deep.runConfig.sourceBudget,
                          "the shallow angle runs on a smaller budget than the run default")
    }

    // MARK: walls

    func testRunCapClampsEachAngleBudget() async throws {
        // runCap $6 across 3 angles + 1 synthesis = 4 slices → each ≤ $1.50, below the user's $2 cap.
        let project = try makeTempProject()
        let exec = RecordingExecutor()
        _ = await runFanOut(question: "Q", angles: angles(3),
                            config: standardRun(project: project, runCap: 6, perTopicCap: 2),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        for t in exec.researchTopics {
            XCTAssertEqual(t.runConfig.perTopicSpendCapUSD, Decimal(string: "1.5")!)
        }
    }

    func testManualStopHaltsInFlightAngles() async throws {
        let project = try makeTempProject()
        let signal = Signal()
        let exec = ParkingExecutor(signal)
        let task = Task {
            await runFanOut(question: "Q", angles: angles(3), config: standardRun(project: project),
                            executor: exec, clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                            power: SpyPower(), notifier: SpyNotifier())
        }
        await signal.wait()      // at least one angle is running
        task.cancel()            // user pressed Stop
        let report = await task.value
        XCTAssertEqual(report.entries.count, 4)
        let angleEntries = Array(report.entries.dropFirst())   // entry[0] is the synthesis
        XCTAssertTrue(angleEntries.allSatisfy { $0.status == .haltedManual },
                      "in-flight angles hand back a manual-stop partial")
    }

    // MARK: iterative fan-out (round 2+ on unresolved conflicts + gaps)

    func testIterativeStopsWhenDryAndResearchesTheFollowUps() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 1)   // round 1 leaves work; round 2 comes back clean
        let reports = await runIterativeFanOut(question: "How does X work?", angles: angles(2),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 5)
        XCTAssertEqual(reports.count, 2, "one follow-up round, then dry (nothing new) → stop")
        // Round 2 actually researched the conflict + gap round 1 surfaced.
        XCTAssertTrue(exec.researchPrompts.contains { $0.contains("disputed point 1") }, "conflict fed back as an angle")
        XCTAssertTrue(exec.researchPrompts.contains { $0.contains("open question 1") }, "gap fed back as an angle")
    }

    func testIterativeWritesOneMergedRoundTaggedReport() async throws {
        // The whole dive shares ONE run dir → one History row, whose report.json spans all rounds with
        // each entry tagged by the round that produced it (what the History fan diagram reads).
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        _ = await runIterativeFanOut(question: "Q", angles: angles(2),
                                     config: standardRun(project: project), executor: IterativeExecutor(roundsWithWork: 1),
                                     clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                     notifier: SpyNotifier(), maxRounds: 5, runDir: dir)
        XCTAssertEqual(store.listRuns(projectURL: project).count, 1, "one History row for the whole multi-round dive")
        let data = try Data(contentsOf: dir.appendingPathComponent("report.json"))
        let report = try JSONDecoder().decode(RunReport.self, from: data)
        XCTAssertEqual(Set(report.entries.compactMap(\.round)), [1, 2], "entries tagged by their round")
        XCTAssertEqual(report.entries.filter { $0.isSynthesis == true && $0.round != nil }.count, 2,
                       "one synthesis per round")
        XCTAssertEqual(report.entries.filter { $0.noteAction == .reconciled }.count, 1,
                       "plus one reconciliation fusing the dive (round-less → out of the fan diagram)")
    }

    func testFallbackRunRecordsWhyTheEngineDidNotRun() async throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        _ = await runIterativeFanOut(question: "Q", angles: angles(2), config: standardRun(project: project),
                                     executor: FakeExecutor([:]), clock: TestClock(now: fixedStart), store: store,
                                     power: SpyPower(), notifier: SpyNotifier(), maxRounds: 1, runDir: dir,
                                     pipeline: .inProcess(because: "no quorum-engine found"))
        let report = try JSONDecoder().decode(RunReport.self,
                                              from: Data(contentsOf: dir.appendingPathComponent("report.json")))
        XCTAssertEqual(report.pipeline?.name, RunPipeline.inProcessName)
        XCTAssertEqual(report.pipeline?.fallbackReason, "no quorum-engine found")
        let digest = try String(contentsOf: dir.appendingPathComponent("digest.md"), encoding: .utf8)
        XCTAssertTrue(digest.contains("no quorum-engine found"), digest)
    }

    func testNoEntryPassesItsWriteupOffAsItsTranscript() async throws {
        // An angle whose transcriptPath IS its note has no transcript — reopening it replays the answer,
        // not the tool activity that produced it. A missing transcript says so instead of aliasing.
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let report = await runFanOut(question: "Q", angles: angles(2), config: standardRun(project: project),
                                     executor: FakeExecutor([:]), clock: TestClock(now: fixedStart),
                                     store: store, power: SpyPower(), notifier: SpyNotifier(), runDir: dir)

        var seen = Set<String>()
        for entry in report.entries {
            guard let transcript = entry.transcriptPath else { continue }
            XCTAssertNotEqual(transcript, entry.notePath, "\(entry.question) aliased its note as a transcript")
            XCTAssertTrue(transcript.hasSuffix(".transcript.md"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript))
            XCTAssertTrue(seen.insert(transcript).inserted, "each entry gets its own transcript file")
        }
        XCTAssertEqual(seen.count, report.entries.count, "every entry here captured one")
    }

    // MARK: reconciliation (a completed multi-round dive → one current answer, not a round log)

    func testTwoRoundDiveReconcilesIntoOneCurrentAnswer() async throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let notifier = SpyNotifier()
        let reports = await runIterativeFanOut(question: "Is X true?", angles: angles(2),
                                               config: standardRun(project: project), executor: ReconcilingExecutor(),
                                               clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                               notifier: notifier, maxRounds: 5, runDir: dir)
        XCTAssertEqual(reports.count, 2, "round 1 left work, round 2 corrected it → two rounds")

        let merged = try XCTUnwrap(notifier.lastReport)
        let rec = try XCTUnwrap(merged.entries.first { $0.noteAction == .reconciled }, "the dive files a reconciled note")
        XCTAssertEqual(rec.isSynthesis, true)
        XCTAssertNil(rec.round, "reconciliation is the fuse, not a round — stays out of the fan diagram (story 17)")
        XCTAssertGreaterThan(merged.totalCostUSD, reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD },
                             "the run total folds in the reconciliation's own spend — the digest is honest")
        XCTAssertLessThanOrEqual(merged.totalCostUSD, merged.runSpendCapUSD, "still within the one run cap")

        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(rec.notePath)), encoding: .utf8)
        let dated = note.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }
        XCTAssertEqual(dated.count, 1, "exactly one reconciled dated section for the dive — not one per round")
        XCTAssertTrue(note.contains("CURRENTANSWER"), "the note leads with the current answer")
        XCTAssertFalse(note.contains("OVERTURNEDCLAIM"), "round 1's overturned claim is NOT left standing")
        XCTAssertFalse(note.contains("### Open conflicts"), "the reconciled note should not add a conflict subsection")
        XCTAssertFalse(note.contains("### Open questions"), "the reconciled note should not add a question subsection")
    }

    func testReconciliationContextLeavesFormattingOpenEnded() {
        let rounds = [
            TopicFindings(id: "r1", status: .complete, preset: .standard, headline: "Round 1",
                          findings: [], conflicts: [], gaps: [], sourcesConsulted: 1, costUSD: 0,
                          duration: .seconds(1), writeupMarkdown: "First pass", transcript: "", note: nil),
            TopicFindings(id: "r2", status: .complete, preset: .standard, headline: "Round 2",
                          findings: [], conflicts: [], gaps: [], sourcesConsulted: 1, costUSD: 0,
                          duration: .seconds(1), writeupMarkdown: "Second pass", transcript: "", note: nil),
        ]
        let ctx = reconciliationContext(question: "Q", rounds: rounds)
        XCTAssertTrue(ctx.contains("best format"), "the prompt now lets the model choose the shape")
        XCTAssertFalse(ctx.contains("bottom-line-first"), "the prompt no longer hard-codes a rigid format")
    }

    func testReconciliationContextIncludesAngleWriteups() {
        let synthesis = TopicFindings(id: "r1", status: .complete, preset: .standard, headline: "Round 1",
                                      findings: [], conflicts: [], gaps: [], sourcesConsulted: 1, costUSD: 0,
                                      duration: .seconds(1), writeupMarkdown: "Round summary", transcript: "", note: nil)
        let angle = TopicFindings(id: "a1", status: .complete, preset: .standard, headline: "Angle 1",
                                  findings: [Finding(claim: "angle claim", sources: ["https://x.example"], confidence: .high)],
                                  conflicts: [], gaps: [], sourcesConsulted: 1, costUSD: 0,
                                  duration: .seconds(1), writeupMarkdown: "Angle writeup body", transcript: "", note: nil)
        let ctx = reconciliationContext(question: "Q", rounds: [ReconciliationRound(synthesis: synthesis, angles: [angle])])
        XCTAssertTrue(ctx.contains("angle writeups"), "the reconcile prompt includes the underlying angle material")
        XCTAssertTrue(ctx.contains("Angle writeup body"), "the reconcile prompt can inspect the full angle writeup")
        XCTAssertTrue(ctx.contains("angle claim"), "the reconcile prompt also includes the angle findings")
    }

    func testSingleRoundDiveIsNotReconciled() async throws {
        // A converged-on-round-1 dive already reads as one clean answer — no reconciliation, no change.
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let notifier = SpyNotifier()
        let reports = await runIterativeFanOut(question: "Q", angles: angles(3),
                                               config: standardRun(project: project), executor: IterativeExecutor(roundsWithWork: 0),
                                               clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                               notifier: notifier, maxRounds: 5, runDir: dir)
        XCTAssertEqual(reports.count, 1)
        XCTAssertFalse(notifier.lastReport?.entries.contains { $0.noteAction == .reconciled } ?? false,
                       "single-round dive is filed as today — no reconciliation pass")
    }

    func testConvergentDiveSkipsReconciliation() async throws {
        // Two rounds that neither conflict nor add a new claim (round 2 only reaffirms round 1) → the fuse
        // would be pure reformatting, so reconciliation is skipped and the per-round sections stand (#7).
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let notifier = SpyNotifier()
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project), executor: ConvergentDiveExecutor(),
                                               clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                               notifier: notifier, maxRounds: 5, runDir: dir)
        XCTAssertEqual(reports.count, 2, "round 1 left a gap, round 2 ran and reaffirmed it")
        XCTAssertFalse(notifier.lastReport?.entries.contains { $0.noteAction == .reconciled } ?? false,
                       "convergent rounds → no reconciliation pass, the per-round sections stand")
    }

    func testReconciliationSkippedWhenBudgetFloorNotMet() async throws {
        // runCap $0.80 fits two rounds (≈$0.25 each) but leaves <$0.50 (a topic's worth) — so reconciliation
        // is skipped and the per-round sections the rounds wrote stand as-is (fallback, story 8).
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let notifier = SpyNotifier()
        let reports = await runIterativeFanOut(question: "How does Postgres indexing work", angles: angles(2),
                                               config: standardRun(project: project, runCap: Decimal(string: "0.80")!,
                                                                    perTopicCap: Decimal(string: "0.50")!),
                                               executor: IterativeExecutor(roundsWithWork: 1),
                                               clock: TestClock(now: fixedStart), store: store, power: SpyPower(),
                                               notifier: notifier, maxRounds: 5, runDir: dir)
        XCTAssertEqual(reports.count, 2, "two rounds ran before the budget floor")
        XCTAssertFalse(notifier.lastReport?.entries.contains { $0.noteAction == .reconciled } ?? false,
                       "too little budget left → no reconciliation")
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(
            notifier.lastReport?.entries.first { $0.isSynthesis == true }?.notePath)), encoding: .utf8)
        XCTAssertEqual(note.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }.count, 2,
                       "the two per-round sections remain — nothing collapsed")
    }

    func testCancelledDiveSkipsReconciliation() async throws {
        // Cancel after two rounds have begun but before reconciliation → the per-round sections are kept,
        // no reconciliation pass runs (story 10). The guard is `!Task.isCancelled`.
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let notifier = SpyNotifier()
        let signal = Signal()
        let task = Task {
            await runIterativeFanOut(question: "Q", angles: angles(2), config: standardRun(project: project),
                                     executor: StopBeforeReconcileExecutor(signal), clock: TestClock(now: fixedStart),
                                     store: store, power: SpyPower(), notifier: notifier, maxRounds: 5, runDir: dir)
        }
        await signal.wait()   // round 2 has started (round 1 already completed + synthesized)
        task.cancel()
        _ = await task.value
        XCTAssertFalse(notifier.lastReport?.entries.contains { $0.noteAction == .reconciled } ?? false,
                       "a cancelled dive never reconciles — finished rounds are kept")
    }

    func testReconciledDivePreservesAPriorDivesSection() async throws {
        // A later dive on the same topic reconciles ITS rounds but leaves the earlier dive's dated section
        // intact above it — cross-dive history is immutable (story 6).
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        // Prior dive: a single-round fan-out on the topic writes one dated section.
        _ = await runFanOut(question: "Is X true?", angles: angles(2), config: standardRun(project: project),
                            executor: RecordingExecutor(), clock: TestClock(now: fixedStart), store: store,
                            power: SpyPower(), notifier: SpyNotifier())
        // Later dive: two rounds → reconciled.
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart.addingTimeInterval(86_400))
        let notifier = SpyNotifier()
        _ = await runIterativeFanOut(question: "Is X true?", angles: angles(2), config: standardRun(project: project),
                                     executor: ReconcilingExecutor(), clock: TestClock(now: fixedStart.addingTimeInterval(86_400)),
                                     store: store, power: SpyPower(), notifier: notifier, maxRounds: 5, runDir: dir)
        let rec = try XCTUnwrap(notifier.lastReport?.entries.first { $0.noteAction == .reconciled })
        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(rec.notePath)), encoding: .utf8)
        XCTAssertTrue(note.contains("Reconciled writeup."), "the prior dive's synthesis section is preserved")
        XCTAssertTrue(note.contains("CURRENTANSWER"), "the later dive's reconciled answer is appended")
        XCTAssertEqual(note.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }.count, 2,
                       "prior dive's section + one reconciled section for the new dive")
    }

    func testIterativeSingleRoundWhenNothingUnresolved() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 0)   // clean synthesis immediately
        let reports = await runIterativeFanOut(question: "Q", angles: angles(3),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 5)
        XCTAssertEqual(reports.count, 1, "no conflicts/gaps → converged after one round")
    }

    func testIterativeRespectsMaxRoundsBackstop() async throws {
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 99)  // never converges on its own
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project, runCap: 100), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 3)
        XCTAssertEqual(reports.count, 3, "hard round cap stops a non-converging dive")
    }

    func testIterativeTotalSpendNeverExceedsTheOneRunCap() async throws {
        // runCap $1.00, per-round ≈ 2·$0.10 + $0.05 = $0.25. Rounds keep coming (roundsWithWork high) but
        // the SHARED cap is the wall: it stops once <$0.50 (a topic's worth) is left. Σ must stay ≤ cap.
        let project = try makeTempProject()
        let exec = IterativeExecutor(roundsWithWork: 99)
        let cap = Decimal(1)
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project, runCap: cap, perTopicCap: Decimal(string: "0.50")!),
                                               executor: exec, clock: TestClock(now: fixedStart),
                                               store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier(),
                                               maxRounds: 10)
        let total = reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD }
        XCTAssertLessThanOrEqual(total, cap, "the run cap is one wall across ALL rounds")
        XCTAssertLessThan(reports.count, 10, "budget wall stopped it before the round backstop")
    }

    func testIterativeFiresExactlyOneFinishedNotification() async throws {
        let project = try makeTempProject()
        let notifier = SpyNotifier()
        _ = await runIterativeFanOut(question: "Q", angles: angles(2),
                                     config: standardRun(project: project), executor: IterativeExecutor(roundsWithWork: 2),
                                     clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                     power: SpyPower(), notifier: notifier, maxRounds: 5)
        XCTAssertEqual(notifier.count, 1, "one dive → one ping, not one per round")
    }

    func testAngleStaggerTargetSpacesLaunches() {
        let base = fixedStart
        XCTAssertEqual(angleStaggerTarget(base: base, index: 0, step: .seconds(5)), base, "angle 0 never waits")
        XCTAssertEqual(angleStaggerTarget(base: base, index: 3, step: .seconds(5)),
                       base.addingTimeInterval(15), "angle i starts i·step after the run")
        for i in 0..<4 {
            XCTAssertEqual(angleStaggerTarget(base: base, index: i, step: .zero), base,
                           "zero step = no stagger for any angle (keeps the default a no-op)")
        }
    }

    func testFollowUpAnglesMapConflictsAndGaps() {
        let out = followUpAngles(conflicts: [Conflict(claim: "X vs Y", positions: ["a: X", "b: Y"])],
                                 gaps: ["what about Z?"], alreadyAsked: [], limit: 5)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].prompt.contains("X vs Y") && out[0].prompt.contains("a: X"))
        XCTAssertTrue(out[1].prompt.contains("what about Z?"))
    }

    func testFollowUpAnglesDedupAgainstPriorRoundsAndCap() {
        let c = [Conflict(claim: "c1", positions: ["p"]), Conflict(claim: "c2", positions: ["p"])]
        let first = followUpAngles(conflicts: c, gaps: [], alreadyAsked: [], limit: 5)
        let asked = Set(first.map { normalizeSource($0.prompt) })
        let again = followUpAngles(conflicts: c, gaps: ["g1", "g2", "g3"], alreadyAsked: asked, limit: 2)
        XCTAssertTrue(again.allSatisfy { !asked.contains(normalizeSource($0.prompt)) }, "repeat conflicts dropped")
        XCTAssertEqual(again.count, 2, "capped to the limit")
    }

    // MARK: autoresearch (dig until the answer is concrete, not just until questions run out)

    func testAutoresearchDeepensAWeakAnswerThatListsNoGaps() async throws {
        let project = try makeTempProject()
        let exec = WeakSynthesisExecutor(weakRounds: 1)   // round 1: weak, no conflicts/gaps; round 2: concrete
        let reports = await runIterativeFanOut(question: "Is X true?", angles: angles(2),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(),
                                               maxRounds: 5, autoresearch: true)
        XCTAssertEqual(reports.count, 2, "a weak answer with no listed gaps still triggers a deeper round")
        XCTAssertTrue(exec.researchPrompts.contains { $0.contains("shaky claim 1") },
                      "the weak finding was fed back as a verify-it angle")
    }

    func testWithoutAutoresearchAWeakAnswerStopsImmediately() async throws {
        let project = try makeTempProject()
        let exec = WeakSynthesisExecutor(weakRounds: 1)
        let reports = await runIterativeFanOut(question: "Is X true?", angles: angles(2),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(), maxRounds: 5)
        XCTAssertEqual(reports.count, 1, "no conflicts/gaps → old behavior stops even if the answer is weak")
    }

    func testAutoresearchStillStopsOnAConcreteAnswer() async throws {
        let project = try makeTempProject()
        let exec = WeakSynthesisExecutor(weakRounds: 0)   // concrete on round 1
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project), executor: exec,
                                               clock: TestClock(now: fixedStart), store: DiskFindingsStore(),
                                               power: SpyPower(), notifier: SpyNotifier(),
                                               maxRounds: 5, autoresearch: true)
        XCTAssertEqual(reports.count, 1, "concrete answer → stop; don't burn budget digging")
    }

    func testAutoresearchStaysWithinBudgetOnAnUnanswerableQuestion() async throws {
        // Never turns concrete; budget must still be the wall (no infinite dig).
        let project = try makeTempProject()
        let exec = WeakSynthesisExecutor(weakRounds: 99)
        let cap = Decimal(1)
        let reports = await runIterativeFanOut(question: "Q", angles: angles(2),
                                               config: standardRun(project: project, runCap: cap, perTopicCap: Decimal(string: "0.50")!),
                                               executor: exec, clock: TestClock(now: fixedStart),
                                               store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier(),
                                               maxRounds: 50, autoresearch: true)
        let total = reports.reduce(Decimal(0)) { $0 + $1.totalCostUSD }
        XCTAssertLessThanOrEqual(total, cap, "autoresearch still respects the one run cap")
        XCTAssertLessThan(reports.count, 50, "the budget wall stopped the dig before the round backstop")
    }

    func testIsConcreteGate() {
        func synth(_ status: TopicStatus, conflicts: [Conflict] = [], _ findings: [Finding]) -> RunReport.TopicEntry {
            RunReport.TopicEntry(id: "s", question: "q", status: status, preset: .standard, headline: "h",
                                 confidenceSummary: "-", sourcesConsulted: 0, costUSD: 0, durationSeconds: 0,
                                 note: nil, notePath: nil, transcriptPath: nil, isSynthesis: true,
                                 conflicts: conflicts, findings: findings)
        }
        let strong = Finding(claim: "c", sources: ["u"], confidence: .high)
        XCTAssertTrue(isConcrete(synth(.complete, [strong])))
        XCTAssertFalse(isConcrete(synth(.complete, [Finding(claim: "c", sources: [], confidence: .low)])),
                       "all-low-confidence is not a concrete answer")
        XCTAssertFalse(isConcrete(synth(.inconclusive, [])), "inconclusive is not concrete")
        XCTAssertFalse(isConcrete(synth(.complete, conflicts: [Conflict(claim: "x", positions: ["a"])], [strong])),
                       "an unresolved conflict means not yet settled")
    }

    func testSynthesisContextEmitsFindingsAndTrimsProse() {
        // Hybrid input: the structured findings reach the summariser verbatim; the prose writeup is trimmed
        // far below the old 4000-char budget (the summariser only needs the top of it).
        let longBody = String(repeating: "x", count: 5000)
        let angle = TopicFindings(id: "a", status: .complete, preset: .standard, headline: "H",
                                  findings: [Finding(claim: "key claim", sources: ["https://u.example"], confidence: .high)],
                                  sourcesConsulted: 1, costUSD: 0, duration: .seconds(0),
                                  writeupMarkdown: longBody, transcript: "", note: nil)
        let ctx = synthesisContext(question: "Q", angles: [angle])
        XCTAssertTrue(ctx.contains("key claim") && ctx.contains("high") && ctx.contains("https://u.example"),
                      "structured findings (claim · confidence · sources) reach the summariser")
        XCTAssertTrue(ctx.contains("…(truncated)"), "an over-long writeup is trimmed")
        XCTAssertFalse(ctx.contains(String(repeating: "x", count: 1600)),
                       "the prose excerpt is capped well below the old 4000-char budget")
    }

    func testSynthesisContextCarriesAWordBudgetScaledToAngleCount() {
        func angle(_ id: String) -> TopicFindings {
            TopicFindings(id: id, status: .complete, preset: .standard, headline: "H",
                          findings: [], sourcesConsulted: 1, costUSD: 0, duration: .seconds(0),
                          writeupMarkdown: "body", transcript: "", note: nil)
        }
        XCTAssertEqual(ResearchPrompts.synthesisWordBudget(angleCount: 2), 900)
        XCTAssertEqual(ResearchPrompts.synthesisWordBudget(angleCount: 5), 1200)
        XCTAssertEqual(ResearchPrompts.synthesisWordBudget(angleCount: 8), 1500)
        XCTAssertEqual(ResearchPrompts.synthesisWordBudget(angleCount: 20), 1500,
                       "the budget is a clarity ceiling, not a length license")
        let ctx = synthesisContext(question: "Q", angles: (0..<5).map { angle("a\($0)") })
        XCTAssertTrue(ctx.contains("under ~1200 words"),
                      "the summariser gets an explicit length wall scaled to its input")
    }

    func testDivergedAcrossRoundsGate() {
        func round(_ claim: String, conflicts: [Conflict] = []) -> TopicFindings {
            TopicFindings(id: "r", status: .complete, preset: .standard, headline: "h",
                          findings: [Finding(claim: claim, sources: ["u"], confidence: .high)],
                          conflicts: conflicts, sourcesConsulted: 0, costUSD: 0, duration: .seconds(0),
                          writeupMarkdown: "w", transcript: "", note: nil)
        }
        XCTAssertFalse(divergedAcrossRounds([round("stable"), round("stable")]),
                       "a later round that only reaffirms the same claim (no conflict) is redundant")
        XCTAssertTrue(divergedAcrossRounds([round("first"), round("second")]),
                      "a later round that introduces a new claim needs the fuse")
        XCTAssertTrue(divergedAcrossRounds([round("x", conflicts: [Conflict(claim: "d", positions: ["a", "b"])]),
                                            round("x")]),
                      "any unresolved conflict in any round needs the fuse")
        XCTAssertFalse(divergedAcrossRounds([round("solo")]), "fewer than two rounds is never a candidate")
    }

    func testDeepenAnglesTargetsWeakFindingsAndFallsBackToTheQuestion() {
        let out = deepenAngles(findings: [Finding(claim: "shaky", sources: [], confidence: .low),
                                          Finding(claim: "solid", sources: ["u"], confidence: .high)],
                               question: "Is X true?", alreadyAsked: [], limit: 5)
        XCTAssertEqual(out.count, 1, "only the weak finding is re-chased")
        XCTAssertTrue(out[0].prompt.contains("shaky") && !out[0].prompt.contains("solid"))

        let fallback = deepenAngles(findings: [], question: "Is X true?", alreadyAsked: [], limit: 5)
        XCTAssertEqual(fallback.count, 1)
        XCTAssertTrue(fallback[0].prompt.contains("Is X true?"), "no findings → re-attack the whole question")
    }

    func testParseGapsFromSynthesisJSON() {
        let text = "prose\n```json\n{\"headline\":\"h\",\"status\":\"complete\",\"findings\":[],\"gaps\":[\"q1\",\"  \",\"q2\"]}\n```"
        XCTAssertEqual(ResearchOutputParser.parseFinal(text).gaps, ["q1", "q2"], "gaps parsed; blanks dropped")
    }

    // MARK: PRD 03 — evidence travels with the round it was captured in

    func testPersistedRoundCarriesEvidenceOntoEveryEntryAndItsNote() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        // The registry the engine reports run-wide; the per-topic quotes ride on each topic's findings.
        let registry = EvidenceIndex(documents: [
            SourceDocument(sourceID: "s1", url: "https://nature.com/x", title: "Nature", contentType: .pdf,
                           snapshotPath: "sources/s1.md")])
        func findings(_ id: String, marker: String, writeup: String) -> TopicFindings {
            TopicFindings(id: id, status: .complete, preset: .standard, headline: "H \(id)",
                          findings: [Finding(claim: "c", sources: ["https://nature.com/x"], confidence: .high,
                                             citationIDs: [marker])],
                          sourcesConsulted: 1, costUSD: 0, duration: .seconds(0), writeupMarkdown: writeup,
                          transcript: "", note: nil,
                          evidence: EvidenceIndex(citations: [
                            Citation(id: marker, sourceID: "s1", quote: "latency fell 40%",
                                     start: 1, end: 17, match: .exact, page: 4)]))
        }

        let entries = persistFanOutRound(
            synthesis: findings("synthesis", marker: "a1c1", writeup: "Reconciled [^a1c1]."),
            angleFindings: [findings("a1", marker: "c1", writeup: "Angle body [^c1].")],
            angleTitles: ["Latency"], question: "Do cold starts fall?", config: standardRun(project: project),
            store: store, runDir: runDir, priorNotes: [], round: 1, at: fixedStart, evidence: registry)

        XCTAssertEqual(entries.count, 2)
        for e in entries {
            XCTAssertEqual(e.evidence?.documents.map(\.sourceID), ["s1"],
                           "every entry resolves its markers against the run-wide registry")
        }
        XCTAssertEqual(entries[0].evidence?.citation("a1c1")?.match, .exact)
        XCTAssertEqual(entries[1].evidence?.citation("c1")?.match, .exact)

        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(entries[0].notePath)), encoding: .utf8)
        XCTAssertTrue(note.contains("[^a1c1]: [Nature](https://nature.com/x)"),
                      "the durable note names the captured source, not just the quote")
    }

    // MARK: backward compatibility

    func testOldReportWithoutIsSynthesisStillDecodes() throws {
        // A report.json written before `isSynthesis` existed must still load — don't break run history.
        let json = """
        {"startedAt":0,"finishedAt":1,"totalCostUSD":0,"runSpendCapUSD":20,
         "entries":[{"id":"a","question":"q","status":"complete","preset":"standard","headline":"h",
         "confidenceSummary":"1 high","sourcesConsulted":3,"costUSD":0.1,"durationSeconds":5,
         "notePath":null,"transcriptPath":null}]}
        """
        let report = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertNil(report.entries[0].isSynthesis, "absent flag decodes as nil, not a failure")
    }

    // MARK: parser

    func testParseAnglesWellFormed() {
        let text = "prose\n```json\n[{\"title\":\"A\",\"prompt\":\"pa\"},{\"title\":\"B\",\"prompt\":\"pb\"}]\n```"
        let a = ResearchOutputParser.parseAngles(text)
        XCTAssertEqual(a.map(\.title), ["A", "B"])
        XCTAssertEqual(a.map(\.prompt), ["pa", "pb"])
    }

    func testParseAnglesForgivingFieldNames() {
        let a = ResearchOutputParser.parseAngles("```json\n[{\"name\":\"N\",\"question\":\"q1\"}]\n```")
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].title, "N")
        XCTAssertEqual(a[0].prompt, "q1")
    }

    func testParseAnglesMalformedIsEmptyNeverCrashes() {
        XCTAssertTrue(ResearchOutputParser.parseAngles("no json here").isEmpty)
        XCTAssertTrue(ResearchOutputParser.parseAngles("```json\n{not valid}\n```").isEmpty)
        XCTAssertTrue(ResearchOutputParser.parseAngles("```json\n[{\"title\":\"only\"}]\n```").isEmpty,
                      "an angle with no prompt is dropped")
    }

    func testParseAnglesReadsShallowDepthAsDraftPreset() {
        // The planner tags cheap angles "shallow" → draft budget; "deep"/absent inherit the run default.
        // A legacy angle JSON with no depth field must still parse (the third angle → nil preset).
        let a = ResearchOutputParser.parseAngles(
            "```json\n[{\"title\":\"A\",\"prompt\":\"pa\",\"depth\":\"shallow\"}," +
            "{\"title\":\"B\",\"prompt\":\"pb\",\"depth\":\"deep\"}," +
            "{\"title\":\"C\",\"prompt\":\"pc\"}]\n```")
        XCTAssertEqual(a.map(\.preset), [.draft, nil, nil])
    }
}
