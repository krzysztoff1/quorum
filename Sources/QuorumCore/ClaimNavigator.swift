import Foundation

public struct ClaimNavigator: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let cites: [String]

        public init(id: String, cites: [String]) {
            self.id = id
            self.cites = cites
        }
    }

    public let entries: [Entry]
    public private(set) var focusedID: String?
    public private(set) var opened: String?
    private var pinned = false

    public init(entries: [Entry]) { self.entries = entries }

    public var railOpen: Bool { opened != nil }

    private var focusedIndex: Int? { focusedID.flatMap { id in entries.firstIndex { $0.id == id } } }

    public var sources: [String] { focusedIndex.map { entries[$0].cites } ?? [] }

    public var sourcePosition: Int? { opened.flatMap { sources.firstIndex(of: $0) } }

    public mutating func next() { move(by: 1) }

    public mutating func previous() { move(by: -1) }

    public mutating func focus(_ id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        focusedID = id
    }

    public mutating func openFirstSource() {
        pinned = true
        if let first = sources.first { opened = first }
    }

    public mutating func cycleSource(by delta: Int) {
        guard let position = sourcePosition, !sources.isEmpty else { return }
        opened = sources[(position + delta + sources.count) % sources.count]
    }

    public mutating func close() {
        opened = nil
        pinned = false
    }

    public mutating func open(cite: String) {
        if opened == cite {
            close()
            return
        }
        pinned = true
        if let owner = entries.first(where: { $0.cites.contains(cite) }) { focusedID = owner.id }
        opened = cite
    }

    private mutating func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        let index = focusedIndex.map { min(max($0 + delta, 0), entries.count - 1) } ?? 0
        focusedID = entries[index].id
        opened = pinned ? entries[index].cites.first : nil
    }
}
