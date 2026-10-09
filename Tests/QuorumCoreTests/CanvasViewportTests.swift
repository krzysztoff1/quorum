import XCTest
@testable import QuorumCore

/// Pan and zoom as arithmetic the canvas can trust: the world point under the cursor stays under the
/// cursor through a zoom, the zoom stays inside its clamp, and what the viewport says is visible is
/// exactly what a culled renderer may skip.
final class CanvasViewportTests: XCTestCase {

    func testAViewPointIsTheWorldPointScaledThenPanned() {
        let viewport = CanvasViewport(zoom: 2, pan: CGPoint(x: 10, y: 20))

        XCTAssertEqual(viewport.viewPoint(of: CGPoint(x: 5, y: 5)), CGPoint(x: 20, y: 30))
        XCTAssertEqual(viewport.worldPoint(of: CGPoint(x: 20, y: 30)), CGPoint(x: 5, y: 5))
    }

    func testZoomingKeepsTheWorldPointUnderTheCursorFixed() {
        let viewport = CanvasViewport(zoom: 1, pan: CGPoint(x: -100, y: -50))
        let cursor = CGPoint(x: 400, y: 300)
        let held = viewport.worldPoint(of: cursor)

        let zoomed = viewport.zoomed(to: 1.8, about: cursor)

        XCTAssertEqual(zoomed.zoom, 1.8)
        XCTAssertEqual(zoomed.worldPoint(of: cursor).x, held.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.worldPoint(of: cursor).y, held.y, accuracy: 0.001)
    }

    func testZoomIsClampedToItsRange() {
        let viewport = CanvasViewport()

        XCTAssertEqual(viewport.zoomed(to: 100, about: .zero).zoom, CanvasViewport.zoomRange.upperBound)
        XCTAssertEqual(viewport.zoomed(to: 0.01, about: .zero).zoom, CanvasViewport.zoomRange.lowerBound)
    }

    func testAWheelDeltaZoomsExponentiallyAboutTheCursor() {
        let viewport = CanvasViewport()
        let cursor = CGPoint(x: 200, y: 200)

        let zoomedIn = viewport.zoomed(byWheel: -50, about: cursor)
        let zoomedOut = viewport.zoomed(byWheel: 50, about: cursor)

        XCTAssertGreaterThan(zoomedIn.zoom, 1)
        XCTAssertLessThan(zoomedOut.zoom, 1)
        XCTAssertEqual(zoomedIn.worldPoint(of: cursor).x, viewport.worldPoint(of: cursor).x,
                       accuracy: 0.001)
    }

    func testPanningMovesTheViewNotTheWorld() {
        let viewport = CanvasViewport(zoom: 1, pan: .zero).panned(by: CGSize(width: 30, height: -10))

        XCTAssertEqual(viewport.pan, CGPoint(x: 30, y: -10))
        XCTAssertEqual(viewport.zoom, 1)
    }

    func testFittingContainsTheWholeGraphCentred() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let viewport = CanvasViewport.fitting(bounds, in: CGSize(width: 600, height: 600), padding: 50)

        let visible = viewport.visibleWorldRect(in: CGSize(width: 600, height: 600))
        XCTAssertTrue(visible.contains(bounds))
        XCTAssertEqual(visible.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(visible.midY, bounds.midY, accuracy: 1)
    }

    func testFittingASmallGraphDoesNotZoomPastFullSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let viewport = CanvasViewport.fitting(bounds, in: CGSize(width: 800, height: 600), padding: 40)

        XCTAssertLessThanOrEqual(viewport.zoom, 1)
    }

    func testCenteringPutsTheRectInTheMiddleWithoutChangingZoom() {
        let viewport = CanvasViewport(zoom: 1.3, pan: .zero)
        let target = CGRect(x: 500, y: 700, width: 200, height: 100)

        let centered = viewport.centered(on: target, in: CGSize(width: 800, height: 600))

        XCTAssertEqual(centered.zoom, 1.3)
        XCTAssertEqual(centered.viewPoint(of: CGPoint(x: target.midX, y: target.midY)),
                       CGPoint(x: 400, y: 300))
    }

    func testTheVisibleWorldRectRoundTripsThroughTheTransform() {
        let viewport = CanvasViewport(zoom: 0.5, pan: CGPoint(x: 100, y: -40))
        let visible = viewport.visibleWorldRect(in: CGSize(width: 800, height: 600))

        XCTAssertEqual(visible.origin, viewport.worldPoint(of: .zero))
        XCTAssertEqual(visible.width, 800 / 0.5, accuracy: 0.001)
        XCTAssertEqual(visible.height, 600 / 0.5, accuracy: 0.001)
    }

    func testDetailDegradesAsTheZoomFallsAway() {
        XCTAssertTrue(CanvasViewport(zoom: 0.4, pan: .zero).isChipZoom)
        XCTAssertFalse(CanvasViewport(zoom: 0.8, pan: .zero).isChipZoom)
        XCTAssertTrue(CanvasViewport(zoom: 1, pan: .zero).showsEdgeLabels)
        XCTAssertFalse(CanvasViewport(zoom: 0.5, pan: .zero).showsEdgeLabels)
        XCTAssertTrue(CanvasViewport(zoom: 1, pan: .zero).showsPorts)
        XCTAssertFalse(CanvasViewport(zoom: 0.4, pan: .zero).showsPorts)
        XCTAssertEqual(CanvasViewport(zoom: 1, pan: .zero).gridAlpha, 1)
        XCTAssertEqual(CanvasViewport(zoom: 0.25, pan: .zero).gridAlpha, 0)
    }
}
