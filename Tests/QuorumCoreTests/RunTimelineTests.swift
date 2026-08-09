import XCTest
@testable import QuorumCore

/// The time-lane trace: a run laid out as lanes on a shared clock, with stalls surfaced and
/// cross-angle source overlap tied together. Pure geometry over timestamps — no UI, no spend.
final class RunTimelineTests: XCTestCase {

    private func at(_ seconds: TimeInterval) -> Date { fixedStart.addingTimeInterval(seconds) }

    private func lane(_ id: String, status: TopicStatus = .running,
                      _ events: [TimelineEvent] = [], writingAt: TimeInterval? = nil,
                      finishedAt: TimeInterval? = nil) -> TimelineLane {
        TimelineLane(id: id, title: id.uppercased(), status: status, events: events,
                     writingStartedAt: writingAt.map(at), finishedAt: finishedAt.map(at))
    }

    private func fetch(_ url: String, _ seconds: TimeInterval) -> TimelineEvent {
        TimelineEvent(at: at(seconds), mark: .fetch, label: url)
    }

    private func search(_ query: String, _ seconds: TimeInterval) -> TimelineEvent {
        TimelineEvent(at: at(seconds), mark: .search, label: query)
    }

    // MARK: tool names → marks

    func testMarkReadsBothCliAndEngineToolNames() {
        XCTAssertEqual(TimelineMark(toolName: "WebSearch"), .search)
        XCTAssertEqual(TimelineMark(toolName: "web_search"), .search)
        XCTAssertEqual(TimelineMark(toolName: "mcp__quorum__web_search"), .search)
        XCTAssertEqual(TimelineMark(toolName: "WebFetch"), .fetch)
        XCTAssertEqual(TimelineMark(toolName: "mcp__quorum__web_fetch"), .fetch)
        XCTAssertEqual(TimelineMark(toolName: "Read"), .read)
        XCTAssertEqual(TimelineMark(toolName: "Grep"), .read)
    }

    // MARK: horizontal placement

    func testFractionPlacesAnEventProportionallyAcrossTheSpan() {
        let t = RunTimeline(lanes: [lane("a1", [fetch("https://x.com/a", 50)])],
                            start: at(0), now: at(100))
        XCTAssertEqual(t.fraction(of: at(50)), 0.5, accuracy: 0.0001)
    }

    func testFractionClampsOutsideTheSpan() {
        let t = RunTimeline(lanes: [lane("a1")], start: at(0), now: at(100))
        XCTAssertEqual(t.fraction(of: at(-30)), 0)
        XCTAssertEqual(t.fraction(of: at(300)), 1)
    }

    func testInstantaneousRunStaysFiniteInsteadOfDividingByZero() {
        let t = RunTimeline(lanes: [lane("a1", [fetch("https://x.com/a", 0)])],
                            start: at(0), now: at(0))
        XCTAssertTrue(t.fraction(of: at(0)).isFinite)
        XCTAssertEqual(t.fraction(of: at(0)), 0)
    }

    func testSpanStretchesPastNowWhenAnEventArrivedLater() {
        // A replayed or clock-skewed event beyond `now` must stay on-canvas, not clamp into the edge.
        let t = RunTimeline(lanes: [lane("a1", [fetch("https://x.com/a", 200)])],
                            start: at(0), now: at(100))
        XCTAssertEqual(t.fraction(of: at(200)), 1, accuracy: 0.0001)
        XCTAssertEqual(t.fraction(of: at(100)), 0.5, accuracy: 0.0001)
    }

    // MARK: stalls

    func testRunningLaneIsStalledAfterItsLastEventGoesQuiet() {
        let l = lane("a3", [fetch("https://x.com/a", 10)])
        let t = RunTimeline(lanes: [l], start: at(0), now: at(200))
        XCTAssertEqual(t.stall(of: l) ?? 0, 190, accuracy: 0.0001)
    }

    func testRecentActivityIsNotAStall() {
        let l = lane("a1", [fetch("https://x.com/a", 195)])
        let t = RunTimeline(lanes: [l], start: at(0), now: at(200))
        XCTAssertNil(t.stall(of: l))
    }

    func testFinishedLaneNeverReadsAsStalled() {
        let l = lane("a2", status: .complete, [fetch("https://x.com/a", 10)], finishedAt: 20)
        let t = RunTimeline(lanes: [l], start: at(0), now: at(600))
        XCTAssertNil(t.stall(of: l))
    }

    func testSilentLaneStallsFromTheRunStart() {
        let l = lane("a4")
        let t = RunTimeline(lanes: [l], start: at(0), now: at(120))
        XCTAssertEqual(t.stall(of: l) ?? 0, 120, accuracy: 0.0001)
    }

    func testWritingCountsAsActivityForStallDetection() {
        // An angle mid-writeup emits no tool calls for minutes; that is progress, not a stall.
        let l = lane("a1", [fetch("https://x.com/a", 10)], writingAt: 190)
        let t = RunTimeline(lanes: [l], start: at(0), now: at(200))
        XCTAssertNil(t.stall(of: l))
    }

    // MARK: cross-angle source overlap

    func testSourceReachedByTwoBlindAnglesBecomesATie() {
        let a1 = lane("a1", [fetch("https://nature.com/articles/x", 30)])
        let a2 = lane("a2", [fetch("https://nature.com/articles/x", 80)])
        let t = RunTimeline(lanes: [a1, a2], start: at(0), now: at(100))
        XCTAssertEqual(t.ties.count, 1)
        XCTAssertEqual(t.ties.first?.hits.map(\.laneID), ["a1", "a2"])
        XCTAssertEqual(t.ties.first?.host, "nature.com")
    }

    func testSourceOnlyOneAngleFoundIsNotATie() {
        let a1 = lane("a1", [fetch("https://nature.com/articles/x", 30)])
        let a2 = lane("a2", [fetch("https://iaea.org/y", 40)])
        XCTAssertTrue(RunTimeline(lanes: [a1, a2], start: at(0), now: at(100)).ties.isEmpty)
    }

    func testTieIgnoresSchemeWwwTrailingSlashAndTrackingQuery() {
        let a1 = lane("a1", [fetch("http://www.nature.com/articles/x/", 30)])
        let a2 = lane("a2", [fetch("https://nature.com/articles/x?utm_source=news", 80)])
        XCTAssertEqual(RunTimeline(lanes: [a1, a2], start: at(0), now: at(100)).ties.count, 1)
    }

    func testTieUsesEachLanesEarliestHit() {
        let a1 = lane("a1", [fetch("https://nature.com/x", 30), fetch("https://nature.com/x", 90)])
        let a2 = lane("a2", [fetch("https://nature.com/x", 60)])
        let tie = RunTimeline(lanes: [a1, a2], start: at(0), now: at(100)).ties.first
        XCTAssertEqual(tie?.hits.first?.at, at(30))
        XCTAssertEqual(tie?.hits.count, 2)
    }

    func testTheSameQueryRunByTwoAnglesIsNotSharedEvidence() {
        let a1 = lane("a1", [search("fusion breakeven", 30)])
        let a2 = lane("a2", [search("fusion breakeven", 60)])
        XCTAssertTrue(RunTimeline(lanes: [a1, a2], start: at(0), now: at(100)).ties.isEmpty)
    }

    func testTiesAreOrderedByWhenTheyConverged() {
        let a1 = lane("a1", [fetch("https://late.com/x", 70), fetch("https://early.com/y", 10)])
        let a2 = lane("a2", [fetch("https://late.com/x", 80), fetch("https://early.com/y", 20)])
        let hosts = RunTimeline(lanes: [a1, a2], start: at(0), now: at(100)).ties.map(\.host)
        XCTAssertEqual(hosts, ["early.com", "late.com"])
    }

    // MARK: axis

    func testAxisUsesRoundIntervalsOverALongRun() {
        let t = RunTimeline(lanes: [lane("a1")], start: at(0), now: at(480))
        XCTAssertEqual(t.axis.map(\.label), ["0:00", "2:00", "4:00", "6:00", "8:00"])
    }

    func testAxisStaysFineGrainedOnAShortRun() {
        let t = RunTimeline(lanes: [lane("a1")], start: at(0), now: at(40))
        XCTAssertEqual(t.axis.map(\.label), ["0:00", "0:10", "0:20", "0:30", "0:40"])
    }

    func testAxisLabelsMinutesPastAnHour() {
        let t = RunTimeline(lanes: [lane("a1")], start: at(0), now: at(3600))
        XCTAssertEqual(t.axis.last?.label, "60:00")
    }

    // MARK: lane bookkeeping

    func testEventsGetLaneUniqueIDsEvenWhenIdentical() {
        let l = lane("a1", [fetch("https://x.com/a", 10), fetch("https://x.com/a", 10)])
        XCTAssertEqual(Set(l.events.map(\.id)).count, 2)
    }

    func testRunningLaneDurationRunsToNowAndFinishedLaneStopsAtItsEnd() {
        let running = lane("a1", [fetch("https://x.com/a", 10)])
        let done = lane("a2", status: .complete, [fetch("https://x.com/b", 10)], finishedAt: 60)
        let t = RunTimeline(lanes: [running, done], start: at(0), now: at(200))
        XCTAssertEqual(t.duration(of: running), 200, accuracy: 0.0001)
        XCTAssertEqual(t.duration(of: done), 60, accuracy: 0.0001)
    }

    func testStartFallsBackToTheEarliestEventWhenNoneWasGiven() {
        let t = RunTimeline(lanes: [lane("a1", [fetch("https://x.com/a", 40)])], start: nil, now: at(100))
        XCTAssertEqual(t.fraction(of: at(40)), 0)
    }

    func testWritingBandSpansFromFirstOutputToTheLanesEnd() {
        let l = lane("a1", status: .complete, [fetch("https://x.com/a", 10)],
                     writingAt: 50, finishedAt: 100)
        let t = RunTimeline(lanes: [l], start: at(0), now: at(200))
        let band = t.writingBand(of: l)
        XCTAssertEqual(band?.lowerBound ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(band?.upperBound ?? -1, 0.5, accuracy: 0.0001)
    }

    func testNoWritingBandBeforeTheFirstOutputToken() {
        let l = lane("a1", [fetch("https://x.com/a", 10)])
        XCTAssertNil(RunTimeline(lanes: [l], start: at(0), now: at(200)).writingBand(of: l))
    }
}
