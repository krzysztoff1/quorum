import Foundation

/// Which pipeline actually produced a run. `quorum-engine run` is the flagship path — grounding, the
/// validator loop, captured snapshots; the in-process Swift orchestration is the fallback the app takes
/// when no engine binary resolves, and it has none of those. A run's artifacts look almost identical
/// either way, so a reader who finds no verdicts cannot tell whether the answer survived judgement or was
/// never judged. That difference is recorded here and badged everywhere the run is read.
public struct RunPipeline: Sendable, Codable, Equatable {
    public static let engineName = "quorum-engine"
    public static let inProcessName = "in-process"
    public static let legacyBadge = "legacy pipeline — no validation"

    public let name: String
    /// The stream protocol the engine actually spoke, so a stale binary is visible in the artifacts rather
    /// than only in what is missing from them. Nil when nothing announced one.
    public let protocolVersion: Int?
    public let engineVersion: String?
    public let build: String?
    public let fallbackReason: String?

    public init(name: String, protocolVersion: Int? = nil, engineVersion: String? = nil,
                build: String? = nil, fallbackReason: String? = nil) {
        self.name = name
        self.protocolVersion = protocolVersion
        self.engineVersion = engineVersion
        self.build = build
        self.fallbackReason = fallbackReason
    }

    public static let inProcess = RunPipeline(name: inProcessName)

    public static func inProcess(because reason: String?) -> RunPipeline {
        RunPipeline(name: inProcessName, fallbackReason: reason)
    }

    public static func engine(protocolVersion: Int?, handshake: EngineHandshake? = nil) -> RunPipeline {
        RunPipeline(name: engineName, protocolVersion: protocolVersion ?? handshake?.protocolVersion,
                    engineVersion: handshake?.engineVersion, build: handshake?.build)
    }

    /// Did this run go through the validator loop at all? A `false` here is why a run carries no verdicts.
    public var validates: Bool { name == Self.engineName }

    public var label: String {
        protocolVersion.map { "\(identity) · protocol v\($0)" } ?? identity
    }

    private var identity: String {
        guard let engineVersion else { return name }
        return build.map { "\(name) \(engineVersion) (\($0))" } ?? "\(name) \(engineVersion)"
    }

    /// What to say about a run that never reached the flagship pipeline — or reached an out-of-date one. A
    /// binary a few versions behind still streams something the app can read (every event is additive), so
    /// the only sign that its answer skipped a stage the app expects is the protocol it announced.
    public var badge: String? {
        guard validates else { return Self.legacyBadge }
        let supported = RunStreamParser.supportedProtocolVersion
        guard let protocolVersion, protocolVersion < supported else { return nil }
        return "stale engine — it speaks protocol v\(protocolVersion), this app expects v\(supported)"
    }
}
