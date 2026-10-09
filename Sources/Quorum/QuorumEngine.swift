import Foundation
import QuorumCore

enum QuorumEngine {
    static func resolve() -> EngineResolution {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let candidates = EngineCandidate.ordered(
            override: environment["QUORUM_ENGINE_BIN"],
            bundleResource: Bundle.main.url(forResource: "quorum-engine", withExtension: nil)?.path,
            executable: executable,
            bunPath: BunLocator.find(path: environment["PATH"], home: NSHomeDirectory(),
                                     isExecutable: fm.isExecutableFile(atPath:)),
            fileExists: fm.fileExists(atPath:))
        return EngineResolution.resolve(candidates, isExecutable: fm.isExecutableFile(atPath:),
                                        probe: handshakeOutput)
    }

    private static func handshakeOutput(_ candidate: EngineCandidate) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate.path)
        process.arguments = candidate.arguments + ["version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}
