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
        case override, bundle, devBuild
    }

    public let path: String
    public let origin: Origin

    public init(path: String, origin: Origin) {
        self.path = path
        self.origin = origin
    }

    static let repoBuildPath = "engine/dist/quorum-engine"

    public static func ordered(override: String?, bundleResource: String?, executable: URL?,
                               fileExists: (String) -> Bool) -> [EngineCandidate] {
        var candidates: [EngineCandidate] = []
        if let override, !override.isEmpty { candidates.append(EngineCandidate(path: override, origin: .override)) }
        if let bundleResource { candidates.append(EngineCandidate(path: bundleResource, origin: .bundle)) }
        if let repoBuild = repoBuild(above: executable, fileExists: fileExists) {
            candidates.append(EngineCandidate(path: repoBuild, origin: .devBuild))
        }
        return candidates
    }

    private static func repoBuild(above executable: URL?, fileExists: (String) -> Bool) -> String? {
        var directory = executable?.deletingLastPathComponent()
        while let current = directory, current.path != "/" {
            let build = current.appendingPathComponent(repoBuildPath).path
            if fileExists(current.appendingPathComponent("Package.swift").path), fileExists(build) { return build }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }
}

public struct EngineResolution: Sendable, Equatable {
    public let path: String?
    public let handshake: EngineHandshake?
    public let rejections: [String]

    public static let rebuildHint = "rebuild it with scripts/bundle-engine.sh"

    public static func resolve(_ candidates: [EngineCandidate], isExecutable: (String) -> Bool,
                               probe: (String) -> String?) -> EngineResolution {
        let expected = RunStreamParser.supportedProtocolVersion
        var rejections: [String] = []
        for candidate in candidates {
            guard isExecutable(candidate.path) else {
                rejections.append("\(label(candidate)) is not an executable file")
                continue
            }
            guard let handshake = probe(candidate.path).flatMap(EngineHandshake.parse) else {
                rejections.append("\(candidate.path) did not answer the version handshake — \(rebuildHint)")
                continue
            }
            guard handshake.protocolVersion == expected else {
                rejections.append("\(candidate.path) speaks protocol v\(handshake.protocolVersion), "
                                  + "this app expects v\(expected) — \(rebuildHint)")
                continue
            }
            return EngineResolution(path: candidate.path, handshake: handshake, rejections: rejections)
        }
        if candidates.isEmpty {
            rejections.append("no quorum-engine in the app bundle, QUORUM_ENGINE_BIN or engine/dist — "
                              + "build one with scripts/bundle-engine.sh")
        }
        return EngineResolution(path: nil, handshake: nil, rejections: rejections)
    }

    public var fallbackReason: String? {
        path == nil ? rejections.joined(separator: "; ") : nil
    }

    private static func label(_ candidate: EngineCandidate) -> String {
        candidate.origin == .override ? "QUORUM_ENGINE_BIN=\(candidate.path)" : candidate.path
    }
}
