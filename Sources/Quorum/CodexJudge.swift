import Foundation

/// Cross-family judge: shells out to the OpenAI Codex CLI (`codex exec`) for a one-shot text response,
/// so the benchmark can pit Claude-vs-Claude judging against a non-Claude judge — the single mitigation
/// the LLM-as-judge literature actually validates for the self/family-preference bias.
///
/// Read-only sandbox, no tools, no web. The judge only reads the two writeups already in the prompt.
struct CodexJudge {

    struct JudgeError: LocalizedError { let message: String; var errorDescription: String? { message } }

    let executable: String
    let model: String?
    let timeout: Duration

    init(executable: String = "codex", model: String? = nil, timeout: Duration = .seconds(300)) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    static func isAvailable(executable: String = "codex") -> Bool {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", executable]
        which.standardOutput = Pipe(); which.standardError = Pipe()
        do { try which.run() } catch { return false }
        which.waitUntilExit()
        return which.terminationStatus == 0
    }

    func judge(prompt: String) async throws -> String {
        let outFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-judge-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + buildArguments(prompt: prompt, outputFile: outFile.path)
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw JudgeError(message: "codex exec exit \(process.terminationStatus): \(err.prefix(400))")
        }

        if let text = try? String(contentsOf: outFile, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func buildArguments(prompt: String, outputFile: String) -> [String] {
        var args: [String] = [
            "exec",
            "-s", "read-only",
            "-o", outputFile,
            "-c", "model_reasoning_effort=\"medium\"",
        ]
        if let model { args += ["-m", model] }
        args.append(prompt)
        return args
    }
}
