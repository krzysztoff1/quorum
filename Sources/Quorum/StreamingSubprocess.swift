import Foundation
import QuorumCore

struct ExecutorError: LocalizedError { let message: String; var errorDescription: String? { message } }

/// The one place Quorum launches and streams a research subprocess — shared by the Claude Code CLI
/// executor and the BYOK engine executor (PRD 02 R1). Owns the universal concerns: launch, the NDJSON
/// line loop, cumulative-cost increments to the supervisor, process-kill on cancel, transcript capture.
/// Each parsed line is handed to `onEvent` with the running cost; the caller does its own accumulation.
struct StreamingSubprocess {
    let executableURL: URL
    let arguments: [String]
    let currentDirectory: URL
    var environment: [String: String]? = nil   // nil → inherit parent env (CLI); engine gets keys injected

    struct Outcome { let transcript: String; let finalCostUSD: Decimal }

    func run(_ ctx: RunContext,
             onEvent: (_ line: ResearchOutputParser.StreamLine, _ cumulativeCostUSD: Decimal) -> Void
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        if ctx.cancel.isCancelled { throw CancellationError() }   // cancelled mid-startup → don't launch an orphan
        do { try process.run() } catch {
            throw ExecutorError(message: "Failed to launch \(executableURL.lastPathComponent): \(error.localizedDescription)")
        }
        // Register the kill AFTER launch — terminate() on an unlaunched process raises "task not launched".
        ctx.cancel.onCancel { if process.isRunning { process.terminate() } }

        var transcript = ""
        var reportedCost = Decimal(0)
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                if Task.isCancelled { process.terminate(); break }   // kill on task cancel so waitUntilExit can't block
                transcript += line + "\n"
                guard let ev = ResearchOutputParser.parseStreamLine(line) else { continue }
                if let total = ev.totalCostUSD, total > reportedCost {
                    ctx.onCost(total - reportedCost)   // supervisor accumulates increments
                    reportedCost = total
                }
                onEvent(ev, reportedCost)
            }
        } catch { /* pipe read error — fall through with whatever we captured */ }
        process.waitUntilExit()
        try Task.checkCancellation()   // if the supervisor killed us, let it classify the outcome
        return Outcome(transcript: transcript, finalCostUSD: reportedCost)
    }
}
