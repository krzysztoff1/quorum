import Foundation

public struct RunPipeline: Sendable, Codable, Equatable {
    public static let engineName = "quorum-engine"

    public let name: String
    public let protocolVersion: Int?
    public let engineVersion: String?
    public let build: String?

    public init(name: String, protocolVersion: Int? = nil, engineVersion: String? = nil, build: String? = nil) {
        self.name = name
        self.protocolVersion = protocolVersion
        self.engineVersion = engineVersion
        self.build = build
    }

    public static func engine(protocolVersion: Int?, handshake: EngineHandshake? = nil) -> RunPipeline {
        RunPipeline(name: engineName, protocolVersion: protocolVersion ?? handshake?.protocolVersion,
                    engineVersion: handshake?.engineVersion, build: handshake?.build)
    }

    public var label: String {
        protocolVersion.map { "\(identity) · protocol v\($0)" } ?? identity
    }

    private var identity: String {
        guard let engineVersion else { return name }
        return build.map { "\(name) \(engineVersion) (\($0))" } ?? "\(name) \(engineVersion)"
    }
}
