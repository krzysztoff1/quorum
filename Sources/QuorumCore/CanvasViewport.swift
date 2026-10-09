import CoreGraphics
import Foundation

/// Where the reader is looking, as arithmetic: a zoom and a pan mapping world points to view points.
/// The one invariant everything hangs on is that zooming holds the world point under the cursor still —
/// a zoom that drifts is a canvas the reader has to chase.
public struct CanvasViewport: Sendable, Equatable {
    public var zoom: CGFloat
    public var pan: CGPoint

    public static let zoomRange: ClosedRange<CGFloat> = 0.25...2.5
    private static let wheelRate: CGFloat = 1.0035

    public init(zoom: CGFloat = 1, pan: CGPoint = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    public func viewPoint(of world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + pan.x, y: world.y * zoom + pan.y)
    }

    public func worldPoint(of view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - pan.x) / zoom, y: (view.y - pan.y) / zoom)
    }

    public func zoomed(to target: CGFloat, about cursor: CGPoint) -> CanvasViewport {
        let clamped = min(max(target, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let held = worldPoint(of: cursor)
        return CanvasViewport(zoom: clamped, pan: CGPoint(x: cursor.x - held.x * clamped,
                                                          y: cursor.y - held.y * clamped))
    }

    public func zoomed(byWheel delta: CGFloat, about cursor: CGPoint) -> CanvasViewport {
        zoomed(to: zoom * pow(Self.wheelRate, -delta), about: cursor)
    }

    public func panned(by delta: CGSize) -> CanvasViewport {
        CanvasViewport(zoom: zoom, pan: CGPoint(x: pan.x + delta.width, y: pan.y + delta.height))
    }

    public func centered(on rect: CGRect, in viewport: CGSize) -> CanvasViewport {
        CanvasViewport(zoom: zoom, pan: CGPoint(x: viewport.width / 2 - rect.midX * zoom,
                                                y: viewport.height / 2 - rect.midY * zoom))
    }

    /// The whole graph on screen at once, no larger than life — a three-node run blown up to fill the
    /// window reads as an error, not an overview.
    public static func fitting(_ bounds: CGRect, in viewport: CGSize,
                               padding: CGFloat = 40) -> CanvasViewport {
        guard bounds.width > 0, bounds.height > 0, viewport.width > 0, viewport.height > 0 else {
            return CanvasViewport()
        }
        let fit = min((viewport.width - padding * 2) / bounds.width,
                      (viewport.height - padding * 2) / bounds.height, 1)
        let zoom = min(max(fit, zoomRange.lowerBound), zoomRange.upperBound)
        return CanvasViewport(zoom: zoom, pan: .zero).centered(on: bounds, in: viewport)
    }

    public func visibleWorldRect(in viewport: CGSize) -> CGRect {
        let origin = worldPoint(of: .zero)
        return CGRect(x: origin.x, y: origin.y,
                      width: viewport.width / zoom, height: viewport.height / zoom)
    }

    /// What the zoom can still afford to draw. Prose goes first, then ports and labels, then the grid —
    /// the shape of the run is the last thing standing.
    public var isChipZoom: Bool { zoom < 0.55 }
    public var showsPorts: Bool { zoom >= 0.5 }
    public var showsEdgeLabels: Bool { zoom >= 0.7 }

    public var gridAlpha: CGFloat {
        min(max((zoom - 0.25) / 0.15, 0), 1)
    }
}
