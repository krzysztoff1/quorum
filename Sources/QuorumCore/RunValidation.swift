import Foundation

/// What the run's validators made of its answer, kept for as long as the run is (PRD 06, 09 R1). The live
/// canvas reads this off the stream; a finished one has nowhere else to read it from, so it rides in
/// `report.json` beside the topics it judged.
public struct RunValidation: Codable, Sendable, Equatable {

    /// One validator task's judgement, exactly as the canvas drew it while the run was going. The status is
    /// the wire's own word — `pass`, `objections(n)`, `skipped` — so a rebuilt verdict and a watched one
    /// resolve through the same mapping and cannot drift apart.
    public struct Verdict: Codable, Sendable, Equatable {
        public let id: String
        public let lens: String
        public let title: String
        public let round: Int
        public let status: String
        public let objections: [RunStreamParser.ObjectionEvent]

        public init(id: String, lens: String, title: String, round: Int, status: String,
                    objections: [RunStreamParser.ObjectionEvent]) {
            self.id = id
            self.lens = lens
            self.title = title
            self.round = round
            self.status = status
            self.objections = objections
        }
    }

    public let status: String
    public let holds: Bool
    public let blocking: Int
    public let spendUSD: Decimal
    public let rounds: Int
    public let objectionsAdmitted: Int
    public let objectionsResolved: Int
    public let objectionsOutstanding: [RunStreamParser.ObjectionEvent]
    public let verdicts: [Verdict]
    /// The located quotes the last round's sweep could not stand their claim up on, so the reader can badge
    /// those chips rather than the answer as a whole (PRD 09 R3).
    public let unsupportedCitationIDs: [String]

    /// One round of the loop as the rail's validation tab reads it: which tasks judged the answer that
    /// round, and what they filed.
    public struct Round: Sendable, Equatable, Identifiable {
        public let number: Int
        public let verdicts: [Verdict]

        public var id: Int { number }

        public var objections: [RunStreamParser.ObjectionEvent] { verdicts.flatMap(\.objections) }

        /// A round holds when nothing blocking was filed against the answer that round. A minor objection is
        /// filed and read, but it never bought another round.
        public var holds: Bool { !objections.contains { $0.severity == "blocking" } }
    }

    /// The loop in order, so the tab reads as what happened rather than as a bag of verdicts.
    public var byRound: [Round] {
        Dictionary(grouping: verdicts, by: \.round)
            .sorted { $0.key < $1.key }
            .map { Round(number: $0.key, verdicts: $0.value) }
    }

    public init(status: String, holds: Bool, blocking: Int, spendUSD: Decimal, rounds: Int,
                objectionsAdmitted: Int, objectionsResolved: Int,
                objectionsOutstanding: [RunStreamParser.ObjectionEvent], verdicts: [Verdict],
                unsupportedCitationIDs: [String] = []) {
        self.status = status
        self.holds = holds
        self.blocking = blocking
        self.spendUSD = spendUSD
        self.rounds = rounds
        self.objectionsAdmitted = objectionsAdmitted
        self.objectionsResolved = objectionsResolved
        self.objectionsOutstanding = objectionsOutstanding
        self.verdicts = verdicts
        self.unsupportedCitationIDs = unsupportedCitationIDs
    }

    public init(_ event: RunStreamParser.ValidationEvent, verdicts: [Verdict]) {
        self.init(status: event.status, holds: event.holds, blocking: event.blocking,
                  spendUSD: event.spendUSD, rounds: event.rounds,
                  objectionsAdmitted: event.objectionsAdmitted,
                  objectionsResolved: event.objectionsResolved,
                  objectionsOutstanding: event.objectionsOutstanding, verdicts: verdicts,
                  unsupportedCitationIDs: event.unsupportedCitationIDs)
    }
}

public extension RunValidation.Verdict {
    init(_ node: RunStreamParser.GraphNodeEvent) {
        self.init(id: node.id, lens: node.lens ?? "", title: node.title, round: node.round,
                  status: node.status, objections: node.objections)
    }
}
