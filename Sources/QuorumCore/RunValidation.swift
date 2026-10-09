import Foundation
public struct RunValidation: Sendable, Equatable {
    public struct Verdict: Sendable, Equatable {
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
    public let unsupportedCitationIDs: [String]
    public struct Round: Sendable, Equatable, Identifiable {
        public let number: Int
        public let verdicts: [Verdict]

        public var id: Int { number }

        public var objections: [RunStreamParser.ObjectionEvent] { verdicts.flatMap(\.objections) }
        public var holds: Bool { !objections.contains { $0.severity == "blocking" } }
    }
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
}
