import Foundation

public struct RunProgress: Equatable, Sendable {
    public let stage: String
    public let stageIndex: Int
    public let stageCount: Int
    public let tasksDone: Int
    public let tasksTotal: Int
    public let sourcesRead: Int
    public let etaSeconds: Int?

    public init(stage: String, stageIndex: Int, stageCount: Int, tasksDone: Int, tasksTotal: Int,
                sourcesRead: Int, etaSeconds: Int? = nil) {
        self.stage = stage
        self.stageIndex = stageIndex
        self.stageCount = stageCount
        self.tasksDone = tasksDone
        self.tasksTotal = tasksTotal
        self.sourcesRead = sourcesRead
        self.etaSeconds = etaSeconds
    }

    public var label: String {
        var parts = ["\(stageWord) · step \(stageIndex) of \(stageCount)"]
        if tasksTotal > 0 { parts.append("\(tasksDone) of \(tasksTotal) tasks") }
        if sourcesRead > 0 { parts.append("\(sourcesRead) \(sourcesRead == 1 ? "source" : "sources") read") }
        if let remaining = remainingLabel { parts.append(remaining) }
        return parts.joined(separator: " · ")
    }

    private var stageWord: String {
        switch stage {
        case "research": return "Researching"
        case "draft": return "Drafting"
        case "check": return "Checking"
        case "answer": return "Finishing"
        default: return stage.prefix(1).uppercased() + stage.dropFirst()
        }
    }

    private var remainingLabel: String? {
        guard let etaSeconds else { return nil }
        if etaSeconds < 60 { return "under a minute left" }
        return "about \((etaSeconds + 30) / 60) min left"
    }
}
