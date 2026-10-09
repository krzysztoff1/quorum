import CoreGraphics
import Foundation

/// The side of a card a wire attaches to, and so the direction its curve sets out in.
public enum PortFace: Sendable, Equatable {
    case top, bottom, leading, trailing

    var direction: CGVector {
        switch self {
        case .top:      return CGVector(dx: 0, dy: -1)
        case .bottom:   return CGVector(dx: 0, dy: 1)
        case .leading:  return CGVector(dx: -1, dy: 0)
        case .trailing: return CGVector(dx: 1, dy: 0)
        }
    }
}

/// One wire: a cubic bezier from port to port. `midpoint` is where a label or a button belongs;
/// `polyline` is the same curve as segments, for crossing tests and hit testing.
public struct EdgeCurve: Sendable, Equatable {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    public var midpoint: CGPoint { point(at: 0.5) }

    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    public func polyline(samples: Int = 24) -> [CGPoint] {
        (0...samples).map { point(at: CGFloat($0) / CGFloat(samples)) }
    }
}

/// How far a control point extends from its port: half the distance when the target lies ahead of the
/// face, a square-root bulge when it lies behind — the bulge is what keeps a wire whose target is behind
/// it arcing out and back instead of collapsing into the card it left.
public enum EdgeGeometry {
    public static let curvature: CGFloat = 0.25

    public static func controlOffset(distance: CGFloat, curvature: CGFloat = curvature) -> CGFloat {
        distance >= 0 ? distance / 2 : curvature * 25 * (-distance).squareRoot()
    }

    public static func curve(from start: CGPoint, fromFace: PortFace,
                             to end: CGPoint, toFace: PortFace) -> EdgeCurve {
        EdgeCurve(start: start,
                  control1: control(at: start, face: fromFace, toward: end),
                  control2: control(at: end, face: toFace, toward: start),
                  end: end)
    }

    private static func control(at point: CGPoint, face: PortFace, toward other: CGPoint) -> CGPoint {
        let direction = face.direction
        let ahead = (other.x - point.x) * direction.dx + (other.y - point.y) * direction.dy
        let offset = controlOffset(distance: ahead)
        return CGPoint(x: point.x + direction.dx * offset, y: point.y + direction.dy * offset)
    }
}
