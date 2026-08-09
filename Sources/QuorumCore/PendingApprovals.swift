import Foundation

/// The one sentence an offer is worth interrupting someone for.
public struct PendingApprovalAlert: Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// The offers a run has left standing on the canvas, and whether the person has been told about them. The
/// wave never waits on one, so an offer nobody notices simply expires — and an offer announced twice is
/// how a run that steers itself becomes a run that nags.
public struct PendingApprovals: Sendable, Equatable {
    public private(set) var ids: [String] = []
    private var announced: Set<String> = []

    public init() {}

    public var count: Int { ids.count }

    /// One offer is two buttons on its own card; several are a chore, and a chore needs a single verdict.
    public var showsBulkActions: Bool { count > 1 }

    public var pillLabel: String? { count == 0 ? nil : "\(count) waiting on you" }

    /// Fold the run's current shape in, and answer with what is worth a notification. Nothing is announced
    /// while the app is in front of the person — the canvas is already saying it — and nothing is announced
    /// twice, so walking away later is not a reason to be told again.
    @discardableResult
    public mutating func observe(_ graph: ResearchGraph, appIsActive: Bool) -> PendingApprovalAlert? {
        let offers = graph.pendingOffers
        ids = offers.map(\.id)
        let unannounced = offers.filter { !announced.contains($0.id) }
        for offer in offers { announced.insert(offer.id) }
        guard !unannounced.isEmpty, !appIsActive else { return nil }
        return PendingApprovalAlert(title: "Quorum — waiting on you", body: body(offers))
    }

    private func body(_ offers: [GraphNode]) -> String {
        guard offers.count > 1 else { return offers.first?.title ?? "" }
        return "\(offers.count) proposed inquiries are waiting on you"
    }
}

extension ResearchGraph {
    /// Questions the RUN raised and cannot spend on until someone rules. A planned angle waiting on the
    /// same canvas is not one of these: nothing has been launched yet, so nobody is being held up.
    public var pendingOffers: [GraphNode] {
        nodes.filter { $0.kind == .question && $0.isPending }
    }
}
