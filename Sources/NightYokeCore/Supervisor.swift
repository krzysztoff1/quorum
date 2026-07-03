import Foundation

/// One topic's outcome plus whether the whole run should stop (run spend cap crossed).
public struct TopicOutcome: Sendable {
    public let findings: TopicFindings
    public let runStopped: Bool
}

/// Watches one topic's streamed cost + elapsed time and pulls the cord on a breach. The walls the
/// CLI can't enforce itself live here; on a kill the last partial findings are preserved.
public enum Supervisor {

    /// `onCharge` (optional) observes every streamed cost increment for this topic. The serial path
    /// leaves it nil; the parallel fan-out passes it so a shared ledger can enforce the *aggregate*
    /// run cap (a per-topic start snapshot of `runSpent` can't, since siblings spend concurrently).
    public static func supervise(_ prepared: PreparedTopic, executor: ResearchExecutor,
                                 clock: RunClock, runSpent: Decimal, runCap: Decimal,
                                 startedAt: Date,
                                 onCharge: (@Sendable (Decimal) -> Void)? = nil) async -> TopicOutcome {
        let token = CancellationToken()
        let monitor = TopicMonitor(perTopicCap: prepared.runConfig.perTopicSpendCapUSD,
                                   runRemaining: runCap - runSpent, token: token)
        let ctx = RunContext(clock: clock, cancel: token,
                             onCost: { monitor.addCost($0); onCharge?($0) },
                             onPartial: { monitor.setPartial($0) })
        let deadline = startedAt.addingTimeInterval(prepared.runConfig.perTopicTimeout.seconds)

        return await withTaskCancellationHandler {
            // The executor runs in its own Task so a breach (or external stop) can cancel it.
            let work = Task { () -> Result<TopicFindings, Error> in
                do { return .success(try await executor.run(prepared, ctx)) }
                catch { return .failure(error) }
            }
            token.onCancel { work.cancel() }

            // Independent timer enforces the wall-clock timeout even if the executor emits nothing.
            let timer = Task {
                try? await clock.sleep(until: deadline)
                if !Task.isCancelled { monitor.markTimedOut() }
            }

            let runResult = await work.value
            timer.cancel()

            let snap = monitor.snapshot()
            let cost = snap.cost
            let duration = Duration.seconds(max(0, clock.now().timeIntervalSince(startedAt)))

            // Walls first — they override whatever the executor happened to return.
            if snap.timedOut {
                return TopicOutcome(
                    findings: partialFindings(prepared, .haltedTime, snap.partial, cost, duration,
                                              note: "hit the per-topic time wall — findings incomplete"),
                    runStopped: false)
            }
            if snap.spendBreached {
                let note = snap.runCapBreached
                    ? "hit the run spend cap — findings incomplete"
                    : "hit the per-topic spend wall — findings incomplete"
                return TopicOutcome(
                    findings: partialFindings(prepared, .haltedSpend, snap.partial, cost, duration, note: note),
                    runStopped: snap.runCapBreached)
            }

            switch runResult {
            case .success(let f):
                // Clean finish — keep the executor's content/status, stamp authoritative id/preset/cost/time.
                let stamped = TopicFindings(
                    id: prepared.id, status: f.status, preset: prepared.preset,
                    headline: f.headline, findings: f.findings, conflicts: f.conflicts, gaps: f.gaps,
                    sourcesConsulted: f.sourcesConsulted,
                    costUSD: cost > 0 ? cost : f.costUSD, duration: duration,
                    writeupMarkdown: f.writeupMarkdown, transcript: f.transcript, note: f.note,
                    sessionID: f.sessionID, rateLimit: f.rateLimit)
                return TopicOutcome(findings: stamped, runStopped: false)
            case .failure(let e):
                if e is CancellationError {
                    // Cancelled with no wall tripped → external (user pulled Stop, story 23).
                    return TopicOutcome(
                        findings: partialFindings(prepared, .haltedManual, snap.partial, cost, duration,
                                                  note: "stopped manually — findings incomplete"),
                        runStopped: false)
                }
                return TopicOutcome(findings: errorFindings(prepared, cost, duration, note: "\(e)"),
                                    runStopped: false)
            }
        } onCancel: {
            token.cancel()
        }
    }
}

// MARK: - The locked accumulator the executor's callbacks feed

/// Lock-guarded so `onCost` can update-and-check synchronously the instant cost lands (walls are
/// stop-at-limit `>=`, matching the prototype), and trip cancellation inline — deterministic, no
/// actor-hop ordering surprises.
final class TopicMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let perTopicCap: Decimal
    private let runRemaining: Decimal
    private let token: CancellationToken
    private var _cost: Decimal = 0
    private var _partial: PartialFindings?
    private var _spendBreached = false
    private var _runCapBreached = false
    private var _timedOut = false

    init(perTopicCap: Decimal, runRemaining: Decimal, token: CancellationToken) {
        self.perTopicCap = perTopicCap
        self.runRemaining = runRemaining
        self.token = token
    }

    func addCost(_ amt: Decimal) {
        var breach = false
        lock.lock()
        _cost += amt
        if _cost >= perTopicCap { _spendBreached = true; breach = true }
        if _cost >= runRemaining { _spendBreached = true; _runCapBreached = true; breach = true }
        lock.unlock()
        if breach { token.cancel() }   // pull the cord
    }

    func setPartial(_ p: PartialFindings) { lock.withLock { _partial = p } }

    func markTimedOut() {
        lock.withLock { _timedOut = true }
        token.cancel()
    }

    struct Snapshot {
        let cost: Decimal
        let partial: PartialFindings?
        let spendBreached: Bool
        let runCapBreached: Bool
        let timedOut: Bool
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(cost: _cost, partial: _partial, spendBreached: _spendBreached,
                     runCapBreached: _runCapBreached, timedOut: _timedOut)
        }
    }
}

// MARK: - Findings builders for the non-clean outcomes

private func partialFindings(_ p: PreparedTopic, _ status: TopicStatus, _ partial: PartialFindings?,
                             _ cost: Decimal, _ duration: Duration, note: String) -> TopicFindings {
    let body = partial?.writeupMarkdown ?? "_No findings were gathered before this topic was halted._"
    let writeup = "> ⚠️ **Incomplete** — \(note)\n\n" + body
    return TopicFindings(
        id: p.id, status: status, preset: p.preset,
        headline: partial?.headline ?? "Halted before any findings",
        findings: partial?.findings ?? [],
        sourcesConsulted: partial?.sourcesConsulted ?? 0,
        costUSD: cost, duration: duration,
        writeupMarkdown: writeup, transcript: "", note: note)
}

private func errorFindings(_ p: PreparedTopic, _ cost: Decimal, _ duration: Duration, note: String) -> TopicFindings {
    TopicFindings(
        id: p.id, status: .error, preset: p.preset, headline: "Research errored",
        findings: [], sourcesConsulted: 0, costUSD: cost, duration: duration,
        writeupMarkdown: "> ❌ **Error** — \(note)\n", transcript: "", note: note)
}
