import Foundation

public struct EngineHandshake: Sendable, Codable, Equatable {
    public let engineVersion: String
    public let protocolVersion: Int
    public let build: String?

    public init(engineVersion: String, protocolVersion: Int, build: String?) {
        self.engineVersion = engineVersion
        self.protocolVersion = protocolVersion
        self.build = build
    }

    private struct Line: Decodable {
        let engine: String?
        let engine_version: String?
        let protocol_version: Int?
        let build: String?
    }

    public static func parse(_ output: String) -> EngineHandshake? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Line.self, from: data),
                  decoded.engine == RunPipeline.engineName,
                  let protocolVersion = decoded.protocol_version else { continue }
            return EngineHandshake(engineVersion: decoded.engine_version ?? "unknown",
                                   protocolVersion: protocolVersion, build: decoded.build)
        }
        return nil
    }
}

public struct EngineCandidate: Sendable, Equatable {
    public enum Origin: String, Sendable {
        case override, source, bundle, devBuild
    }

    public let path: String
    public let origin: Origin
    public let arguments: [String]

    public init(path: String, origin: Origin, arguments: [String] = []) {
        self.path = path
        self.origin = origin
        self.arguments = arguments
    }

    var description: String {
        let command = ([path] + arguments).joined(separator: " ")
        return origin == .override ? "QUORUM_ENGINE_BIN=\(command)" : command
    }

    static let repoBuildPath = "engine/dist/quorum-engine"
    static let repoSourcePath = "engine/src/index.ts"

    public static func ordered(override: String?, bundleResource: String?, executable: URL?, bunPath: String?,
                               includesSource: Bool, fileExists: (String) -> Bool) -> [EngineCandidate] {
        var candidates: [EngineCandidate] = []
        if let override, !override.isEmpty { candidates.append(EngineCandidate(path: override, origin: .override)) }
        let checkout = checkoutRoot(above: executable, fileExists: fileExists)
        if includesSource, let checkout, fileExists(checkout.appendingPathComponent(repoSourcePath).path) {
            candidates.append(EngineCandidate(path: bunPath ?? "bun", origin: .source,
                                              arguments: [checkout.appendingPathComponent(repoSourcePath).path]))
        }
        if let bundleResource { candidates.append(EngineCandidate(path: bundleResource, origin: .bundle)) }
        if let checkout {
            let build = checkout.appendingPathComponent(repoBuildPath).path
            if fileExists(build) { candidates.append(EngineCandidate(path: build, origin: .devBuild)) }
        }
        return candidates
    }

    private static func checkoutRoot(above executable: URL?, fileExists: (String) -> Bool) -> URL? {
        var directory = executable?.deletingLastPathComponent()
        while let current = directory, current.path != "/" {
            if fileExists(current.appendingPathComponent("Package.swift").path) { return current }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }
}

public enum BunLocator {
    public static func find(path: String?, home: String, isExecutable: (String) -> Bool) -> String? {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/bun" }
        let wherePeopleInstallIt = [
            "\(home)/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "\(home)/.local/share/mise/shims/bun",
        ]
        return (onPath + wherePeopleInstallIt).first(where: isExecutable)
    }
}

public struct EngineCheck: Sendable, Equatable {
    public let candidate: EngineCandidate
    public let accepted: Bool
    public let detail: String
}

public struct EngineDoctorRow: Sendable, Equatable, Identifiable {
    public let title: String
    public let detail: String
    public let ok: Bool
    public var id: String { title }
}

public struct EngineResolution: Sendable, Equatable {
    public let path: String?
    public let arguments: [String]
    public let handshake: EngineHandshake?
    public let checks: [EngineCheck]

    public static let rebuildHint = "rebuild it with scripts/bundle-engine.sh"
    static let sourceHint = "run `bun install` in the engine/ folder"

    public static func resolve(_ candidates: [EngineCandidate], isExecutable: (String) -> Bool,
                               probe: (EngineCandidate) -> String?,
                               expectedBundleBuild: String? = nil) -> EngineResolution {
        let expected = RunStreamParser.supportedProtocolVersion
        var checks: [EngineCheck] = []
        for candidate in candidates {
            guard isExecutable(candidate.path) else {
                checks.append(rejected(candidate, notExecutableDetail(candidate)))
                continue
            }
            guard let handshake = probe(candidate).flatMap(EngineHandshake.parse) else {
                checks.append(rejected(candidate, "did not answer the version handshake — \(hint(for: candidate))"))
                continue
            }
            guard handshake.protocolVersion == expected else {
                checks.append(rejected(candidate, "speaks protocol v\(handshake.protocolVersion), "
                                       + "this app expects v\(expected) — \(hint(for: candidate))"))
                continue
            }
            if candidate.origin == .bundle, let expectedBundleBuild, handshake.build != expectedBundleBuild {
                checks.append(rejected(candidate, "holds engine build \(handshake.build ?? "unknown"), but this app "
                                       + "was built with \(expectedBundleBuild) — the bundle is broken, reinstall the app"))
                continue
            }
            checks.append(EngineCheck(candidate: candidate, accepted: true, detail: accepted(handshake)))
            return EngineResolution(path: candidate.path, arguments: candidate.arguments,
                                    handshake: handshake, checks: checks)
        }
        return EngineResolution(path: nil, arguments: [], handshake: nil, checks: checks)
    }

    public var rejections: [String] {
        checks.filter { !$0.accepted }.map { "\($0.candidate.description) \($0.detail)" }
    }

    public var refusalReason: String? {
        guard path == nil else { return nil }
        return checks.isEmpty ? Self.nothingToCheck : rejections.joined(separator: "; ")
    }

    public var doctorRows: [EngineDoctorRow] {
        guard !checks.isEmpty else {
            return [EngineDoctorRow(title: "quorum-engine", detail: Self.nothingToCheck, ok: false)]
        }
        return checks.map { EngineDoctorRow(title: $0.candidate.description, detail: $0.detail, ok: $0.accepted) }
    }

    static let nothingToCheck = "no quorum-engine in the app bundle, QUORUM_ENGINE_BIN, engine/src or engine/dist — "
        + "build one with scripts/bundle-engine.sh"

    private static func rejected(_ candidate: EngineCandidate, _ detail: String) -> EngineCheck {
        EngineCheck(candidate: candidate, accepted: false, detail: detail)
    }

    private static func accepted(_ handshake: EngineHandshake) -> String {
        let build = handshake.build.map { " · build \($0)" } ?? ""
        return "engine \(handshake.engineVersion) · protocol v\(handshake.protocolVersion)\(build)"
    }

    private static func notExecutableDetail(_ candidate: EngineCandidate) -> String {
        candidate.origin == .source
            ? "bun was not found, so the engine cannot run from source — install bun (bun.sh)"
            : "is not an executable file"
    }

    private static func hint(for candidate: EngineCandidate) -> String {
        candidate.origin == .source ? sourceHint : rebuildHint
    }
}
