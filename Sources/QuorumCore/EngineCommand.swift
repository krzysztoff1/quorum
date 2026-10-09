import Foundation

public struct EngineLaunch: Equatable, Sendable {
    public let executable: String
    public let leading: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.leading = arguments
    }

    public init?(_ resolution: EngineResolution) {
        guard let path = resolution.path else { return nil }
        self.init(executable: path, arguments: resolution.arguments)
    }

    public func arguments(for command: [String]) -> [String] { leading + command }
}

public enum EngineCommand {
    public static func detachedRun(store: URL, replay: String? = nil) -> [String] {
        ["run", "--detach", "--store", store.path] + (replay.map { ["--replay", $0] } ?? [])
    }
    public static func cancel(runID: String, store: URL) -> [String] { ["cancel", runID, "--store", store.path] }
    public static func list(store: URL) -> [String] { ["list", "--store", store.path] }
    public static func doctor(store: URL) -> [String] { ["doctor", "--json", "--store", store.path] }
}

public struct EngineFailure: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct RunCreated: Equatable, Sendable {
    public let runID: String
    public let questionID: String
    public let runDir: URL
    public let pid: Int

    public init(runID: String, questionID: String, runDir: URL, pid: Int) {
        self.runID = runID
        self.questionID = questionID
        self.runDir = runDir
        self.pid = pid
    }
}

public struct RunIndexEntry: Equatable, Sendable {
    public let runID: String
    public let questionID: String
    public let runDir: URL
    public let title: String
    public let status: String
    public let pid: Int?

    public init(runID: String, questionID: String, runDir: URL, title: String, status: String, pid: Int?) {
        self.runID = runID
        self.questionID = questionID
        self.runDir = runDir
        self.title = title
        self.status = status
        self.pid = pid
    }
}

public struct EngineDoctorCheck: Equatable, Sendable {
    public let id: String
    public let ok: Bool
    public let detail: String
    public let fix: String?

    public init(id: String, ok: Bool, detail: String, fix: String?) {
        self.id = id
        self.ok = ok
        self.detail = detail
        self.fix = fix
    }
}

public enum EngineReply {

    public static func runCreated(_ stdout: String) -> Result<RunCreated, EngineFailure> {
        guard let line = firstLine(stdout), let raw = decode(RawCreated.self, line) else {
            return .failure(EngineFailure(reason: "quorum-engine said nothing when asked to start the run"))
        }
        if raw.type == "run.created", let runID = raw.run_id, let questionID = raw.question_id, let dir = raw.dir {
            return .success(RunCreated(runID: runID, questionID: questionID,
                                       runDir: URL(fileURLWithPath: dir, isDirectory: true), pid: raw.pid ?? 0))
        }
        return .failure(EngineFailure(reason: raw.error ?? "quorum-engine answered with something this app does not read"))
    }

    public static func runIndex(_ stdout: String) -> [RunIndexEntry] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard let raw = decode(RawIndex.self, String(line)), raw.type == "run",
                  let runID = raw.run_id, let questionID = raw.question_id, let dir = raw.dir else { return nil }
            return RunIndexEntry(runID: runID, questionID: questionID, runDir: URL(fileURLWithPath: dir, isDirectory: true),
                                 title: raw.title ?? "", status: raw.status ?? "", pid: raw.pid)
        }
    }

    public static func toReattach(_ entries: [RunIndexEntry], watching: Set<String>) -> [RunIndexEntry] {
        entries.filter { $0.status == "running" && !watching.contains($0.runID) }
    }

    public static func cancelled(_ stdout: String) -> EngineFailure? {
        guard let line = firstLine(stdout), let raw = decode(RawCancel.self, line) else {
            return EngineFailure(reason: "quorum-engine said nothing when asked to cancel the run")
        }
        return raw.ok == true ? nil : EngineFailure(reason: raw.error ?? "quorum-engine could not cancel the run")
    }

    public static func doctor(_ stdout: String) -> [EngineDoctorCheck] {
        guard let line = firstLine(stdout), let raw = decode(RawDoctor.self, line) else { return [] }
        return (raw.checks ?? []).map { EngineDoctorCheck(id: $0.id, ok: $0.ok, detail: $0.detail, fix: $0.fix) }
    }

    private static func firstLine(_ stdout: String) -> String? {
        stdout.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ line: String) -> T? {
        line.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private struct RawCreated: Decodable {
        let type: String?; let run_id: String?; let question_id: String?; let dir: String?; let pid: Int?
        let error: String?
    }

    private struct RawIndex: Decodable {
        let type: String?; let run_id: String?; let question_id: String?; let dir: String?
        let title: String?; let status: String?; let pid: Int?
    }

    private struct RawCancel: Decodable { let ok: Bool?; let error: String? }

    private struct RawDoctor: Decodable {
        let checks: [Check]?
        struct Check: Decodable { let id: String; let ok: Bool; let detail: String; let fix: String? }
    }
}
