import Foundation
@testable import QuorumCore

struct FakeProbe: ClaudeProbe {
    let result: ProbeResult
    func probe() -> ProbeResult { result }
}

func makeTempProject() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quorum-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

func standardRun(project: URL, runCap: Decimal = 100, perTopicCap: Decimal = Decimal(string: "0.50")!,
                   timeout: Duration = .seconds(300), deadline: Date? = nil,
                   preset: EffortPreset = .standard) -> RunSettings {
    RunSettings(projectURL: project, runSpendCapUSD: runCap, perTopicSpendCapUSD: perTopicCap,
                perTopicTimeout: timeout, runDeadline: deadline, defaultPreset: preset)
}

extension ResearchGraph {
    static func staged(question: String = "Where should we host?", angles: [ResearchAngle]) -> ResearchGraph {
        var graph = ResearchGraph()
        graph.insert(GraphNode(id: rootID, kind: .question, title: question, state: .asked(.approved), origin: .root))
        for angle in angles {
            graph.insert(GraphNode(id: angle.id, kind: .inquiry, title: angle.title, state: .worked(.queued),
                                   origin: .planner, depth: 1, prompt: angle.prompt))
            graph.connect(GraphEdge(from: rootID, to: angle.id, kind: .decomposes))
        }
        return graph
    }
}
