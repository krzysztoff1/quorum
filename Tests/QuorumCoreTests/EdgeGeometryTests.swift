import XCTest
@testable import QuorumCore

/// The wire between two ports is one cubic bezier whose control points extend along each port's facing
/// direction — half the distance when the target lies ahead of the face, a square-root bulge when it lies
/// behind, so a return leg arcs out instead of collapsing into the card it left.
final class EdgeGeometryTests: XCTestCase {

    func testAForwardControlPointExtendsHalfwayAlongTheFace() {
        XCTAssertEqual(EdgeGeometry.controlOffset(distance: 200), 100)
        XCTAssertEqual(EdgeGeometry.controlOffset(distance: 0), 0)
    }

    func testABackwardControlPointBulgesByTheSquareRoot() {
        XCTAssertEqual(EdgeGeometry.controlOffset(distance: -100), 0.25 * 25 * 10, accuracy: 0.001)
        XCTAssertGreaterThan(EdgeGeometry.controlOffset(distance: -1), 0)
    }

    func testADescendingWireCurvesOutOfTheBottomAndIntoTheTop() {
        let curve = EdgeGeometry.curve(from: CGPoint(x: 100, y: 100), fromFace: .bottom,
                                       to: CGPoint(x: 300, y: 300), toFace: .top)

        XCTAssertEqual(curve.start, CGPoint(x: 100, y: 100))
        XCTAssertEqual(curve.end, CGPoint(x: 300, y: 300))
        XCTAssertEqual(curve.control1, CGPoint(x: 100, y: 200))
        XCTAssertEqual(curve.control2, CGPoint(x: 300, y: 200))
    }

    /// A judgement leaves the top of its verdict and lands on the bottom of the answer above — the target
    /// lies ahead of both faces, so the return leg is the same smooth S a descent gets.
    func testAClimbingWireIsSmoothWhenTheTargetLiesAheadOfItsFace() {
        let curve = EdgeGeometry.curve(from: CGPoint(x: 100, y: 300), fromFace: .top,
                                       to: CGPoint(x: 100, y: 100), toFace: .bottom)

        XCTAssertEqual(curve.control1, CGPoint(x: 100, y: 200))
        XCTAssertEqual(curve.control2, CGPoint(x: 100, y: 200))
    }

    /// A wire whose target sits behind its own face must arc away before turning back, or it is drawn
    /// straight through the card it belongs to.
    func testAWireToATargetBehindItsFaceArcsAwayFirst() {
        let curve = EdgeGeometry.curve(from: CGPoint(x: 100, y: 100), fromFace: .bottom,
                                       to: CGPoint(x: 300, y: 50), toFace: .top)

        XCTAssertGreaterThan(curve.control1.y, curve.start.y)
        XCTAssertLessThan(curve.control2.y, curve.end.y)
    }

    func testSideFacesExtendHorizontally() {
        let curve = EdgeGeometry.curve(from: CGPoint(x: 100, y: 100), fromFace: .trailing,
                                       to: CGPoint(x: 400, y: 200), toFace: .leading)

        XCTAssertEqual(curve.control1, CGPoint(x: 250, y: 100))
        XCTAssertEqual(curve.control2, CGPoint(x: 250, y: 200))
    }

    func testTheMidpointIsTheCurveAtItsHalfwayParameter() {
        let curve = EdgeCurve(start: CGPoint(x: 0, y: 0), control1: CGPoint(x: 0, y: 100),
                              control2: CGPoint(x: 200, y: 100), end: CGPoint(x: 200, y: 200))
        let expected = CGPoint(x: 800.0 / 8, y: 800.0 / 8)

        XCTAssertEqual(curve.midpoint.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(curve.midpoint.y, expected.y, accuracy: 0.001)
        XCTAssertEqual(curve.point(at: 0.5).x, expected.x, accuracy: 0.001)
    }

    func testAPolylineSamplesTheCurveEndToEnd() {
        let curve = EdgeGeometry.curve(from: CGPoint(x: 0, y: 0), fromFace: .bottom,
                                       to: CGPoint(x: 100, y: 100), toFace: .top)
        let points = curve.polyline(samples: 8)

        XCTAssertEqual(points.count, 9)
        XCTAssertEqual(points.first, curve.start)
        XCTAssertEqual(points.last, curve.end)
    }
}
