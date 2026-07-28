import Foundation

/// What an agent did at one instant, as the trace draws it.
public enum TimelineMark: String, Sendable, Equatable, Codable {
    case search, fetch, read

    /// Both tool vocabularies land here: the CLI's `WebSearch`/`WebFetch`/`Read` and the engine's
    /// `web_search`/`web_fetch`, with or without the `mcp__quorum__` prefix.
    public init(toolName: String) {
        let name = toolName.lowercased()
        if name.contains("search") { self = .search }
        else if name.contains("fetch") { self = .fetch }
        else { self = .read }
    }
}

/// One tick on a lane. `id` is stamped by the lane it belongs to, so two identical calls at the same
/// instant still draw as two ticks.
public struct TimelineEvent: Identifiable, Sendable, Equatable {
    public var id: String
    public let at: Date
    public let mark: TimelineMark
    public let label: String

    public init(at: Date, mark: TimelineMark, label: String) {
        self.id = "\(at.timeIntervalSince1970)·\(mark.rawValue)·\(label)"
        self.at = at
        self.mark = mark
        self.label = label
    }

    /// The document this tick refers to, normalized so two angles citing the same page tie together.
    /// Searches have none: the same query run twice is not shared evidence.
    public var sourceKey: String? { mark == .search ? nil : RunTimeline.sourceKey(for: label) }
}

public enum LaneRole: String, Sendable, Equatable {
    case angle, synthesis, verify
}

/// One agent's track across the run.
public struct TimelineLane: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let role: LaneRole
    public let round: Int
    public let status: TopicStatus
    public let events: [TimelineEvent]
    public let writingStartedAt: Date?
    public let finishedAt: Date?
    public let costUSD: Decimal

    public init(id: String, title: String, role: LaneRole = .angle, round: Int = 1,
                status: TopicStatus = .running, events: [TimelineEvent] = [],
                writingStartedAt: Date? = nil, finishedAt: Date? = nil, costUSD: Decimal = 0) {
        self.id = id
        self.title = title
        self.role = role
        self.round = round
        self.status = status
        self.events = events.enumerated().map { i, e in
            var stamped = e
            stamped.id = "\(id)#\(i)"
            return stamped
        }
        self.writingStartedAt = writingStartedAt
        self.finishedAt = finishedAt
        self.costUSD = costUSD
    }

    public var sourceCount: Int { events.filter { $0.mark != .search }.count }
    public var searchCount: Int { events.filter { $0.mark == .search }.count }

    /// The last sign of life: a tool call, or the moment the writeup started streaming.
    public var lastActivity: Date? {
        [events.last?.at, writingStartedAt].compactMap { $0 }.max()
    }
}

/// A document two or more blind angles reached independently — the cross-angle agreement the fan-out
/// exists to produce, drawn as a tie between their lanes.
public struct SourceTie: Identifiable, Sendable, Equatable {
    public struct Hit: Sendable, Equatable {
        public let laneID: String
        public let at: Date
    }

    public let key: String
    public let host: String
    public let url: String
    public let hits: [Hit]

    public var id: String { key }
    /// When it stopped being one angle's find and became shared.
    public var convergedAt: Date { hits.count > 1 ? hits[1].at : hits[0].at }
}

public struct AxisTick: Identifiable, Sendable, Equatable {
    public let at: Date
    public let label: String
    public var id: Double { at.timeIntervalSince1970 }
}

/// A run laid out on one clock: lanes placed as fractions of the elapsed span, stalls surfaced, and
/// sources that more than one angle reached tied together. Pure geometry — the view only draws it.
public struct RunTimeline: Sendable {
    public static let stallThreshold: TimeInterval = 45

    public let lanes: [TimelineLane]
    public let start: Date
    public let end: Date
    public let now: Date

    public init(lanes: [TimelineLane], start: Date?, now: Date) {
        self.lanes = lanes
        let firstEvent = lanes.compactMap { $0.events.first?.at }.min()
        self.start = start ?? firstEvent ?? now
        let lastEvent = lanes.compactMap { $0.events.last?.at }.max()
        // A replayed or clock-skewed event past `now` still belongs on the canvas rather than piling
        // up against the right edge.
        self.end = max(now, lastEvent ?? now)
        self.now = now
    }

    public var span: TimeInterval { end.timeIntervalSince(start) }

    public func fraction(of date: Date) -> Double {
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }

    /// How long a lane has been silent, once that silence is long enough to mean something. Only a
    /// lane still claiming to run can stall; a finished one is just finished.
    public func stall(of lane: TimelineLane) -> TimeInterval? {
        guard lane.status == .running else { return nil }
        let idle = now.timeIntervalSince(lane.lastActivity ?? start)
        return idle > Self.stallThreshold ? idle : nil
    }

    /// Elapsed run time a lane occupies — to its own end if it finished, to the playhead if not.
    public func duration(of lane: TimelineLane) -> TimeInterval {
        (lane.finishedAt ?? now).timeIntervalSince(start)
    }

    /// The stretch where the lane was writing its answer rather than gathering.
    public func writingBand(of lane: TimelineLane) -> ClosedRange<Double>? {
        guard let began = lane.writingStartedAt else { return nil }
        let lower = fraction(of: began)
        return lower...max(lower, fraction(of: lane.finishedAt ?? now))
    }

    public var ties: [SourceTie] {
        var earliest: [String: [String: TimelineEvent]] = [:]   // sourceKey → laneID → first hit
        for lane in lanes {
            for event in lane.events {
                guard let key = event.sourceKey else { continue }
                let existing = earliest[key]?[lane.id]
                if existing == nil || event.at < existing!.at {
                    earliest[key, default: [:]][lane.id] = event
                }
            }
        }
        return earliest.compactMap { key, byLane -> SourceTie? in
            guard byLane.count > 1 else { return nil }
            let ordered = byLane.sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }
            let hits = ordered.map { SourceTie.Hit(laneID: $0.key, at: $0.value.at) }
            let url = ordered[0].value.label
            return SourceTie(key: key, host: Self.host(of: url) ?? key, url: url, hits: hits)
        }
        .sorted { ($0.convergedAt, $0.key) < ($1.convergedAt, $1.key) }
    }

    /// Round gridlines — enough to read the clock, few enough not to fence in the lanes.
    public var axis: [AxisTick] {
        guard span > 0 else { return [AxisTick(at: start, label: "0:00")] }
        let candidates: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = candidates.first { span / $0 <= 5 } ?? span
        return stride(from: 0, through: span, by: step).map {
            AxisTick(at: start.addingTimeInterval($0), label: Self.clockLabel($0))
        }
    }

    public static func clockLabel(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func host(of url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "msclkid", "ref", "ref_src", "s", "src",
    ]

    /// Content identity for a source: scheme, `www.`, trailing slash and tracking noise dropped, the
    /// remaining query kept and sorted — so `?v=abc` still distinguishes two pages.
    public static func sourceKey(for value: String) -> String? {
        guard value.hasPrefix("http"), var parts = URLComponents(string: value),
              let host = host(of: value) else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
        var path = parts.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let kept = (parts.queryItems ?? [])
            .filter { !$0.name.lowercased().hasPrefix("utm_") && !trackingParams.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        parts.fragment = nil
        return kept.isEmpty ? host + path : host + path + "?" + kept
    }
}
