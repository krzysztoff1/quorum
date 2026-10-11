import SwiftUI
import QuorumCore

enum QuorumIcon {
    case deep, quick, work, sidebar, search, plus, gap, check
}

struct IconView: View {
    let icon: QuorumIcon
    var size: CGFloat = 14
    var color: Color = Ink.text3
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if pulsing && !reduceMotion && (icon == .deep || icon == .quick) {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { timeline in
                    canvas(phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(phase: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func canvas(phase: Double?) -> some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / 16
            context.scaleBy(x: unit, y: unit)
            draw(&context, phase: phase)
        }
    }

    private func draw(_ context: inout GraphicsContext, phase: Double?) {
        let ink = GraphicsContext.Shading.color(color)
        let faint = GraphicsContext.Shading.color(color.opacity(0.55))
        func dot(_ x: Double, _ y: Double, _ r: Double, alpha: Double = 1) {
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(color.opacity(alpha)))
        }
        func pulse(_ index: Int, count: Int) -> Double {
            guard let phase else { return 1 }
            let wave = (sin((phase * 2.4) - Double(index) * 2.0 * .pi / Double(count)) + 1) / 2
            return 0.35 + 0.65 * wave
        }
        switch icon {
        case .deep:
            var lines = Path()
            lines.move(to: CGPoint(x: 8, y: 4.2)); lines.addLine(to: CGPoint(x: 8, y: 7.8))
            lines.move(to: CGPoint(x: 4.4, y: 11.4)); lines.addLine(to: CGPoint(x: 8, y: 8.6))
            lines.move(to: CGPoint(x: 11.6, y: 11.4)); lines.addLine(to: CGPoint(x: 8, y: 8.6))
            context.stroke(lines, with: faint, lineWidth: 1)
            dot(8, 3.4, 2, alpha: pulse(0, count: 3))
            dot(3.6, 11.8, 2, alpha: pulse(1, count: 3))
            dot(12.4, 11.8, 2, alpha: pulse(2, count: 3))
        case .quick:
            var lead = Path()
            lead.move(to: CGPoint(x: 1.8, y: 8)); lead.addLine(to: CGPoint(x: 7.2, y: 8))
            context.stroke(lead, with: faint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            dot(11, 8, 2.6, alpha: pulse(0, count: 1))
        case .work:
            let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round)
            for (x, y, r) in [(3.0, 8.0, 1.7), (13.2, 2.9, 1.5), (13.2, 8.0, 1.5), (13.2, 13.1, 1.5)] {
                context.stroke(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: ink, style: stroke)
            }
            var curves = Path()
            curves.move(to: CGPoint(x: 4.7, y: 8))
            curves.addCurve(to: CGPoint(x: 11.6, y: 2.9), control1: CGPoint(x: 8.1, y: 8), control2: CGPoint(x: 8.3, y: 2.9))
            curves.move(to: CGPoint(x: 4.7, y: 8)); curves.addLine(to: CGPoint(x: 11.6, y: 8))
            curves.move(to: CGPoint(x: 4.7, y: 8))
            curves.addCurve(to: CGPoint(x: 11.6, y: 13.1), control1: CGPoint(x: 8.1, y: 8), control2: CGPoint(x: 8.3, y: 13.1))
            context.stroke(curves, with: ink, style: stroke)
        case .sidebar:
            context.stroke(Path(roundedRect: CGRect(x: 1.8, y: 2.8, width: 12.4, height: 10.4), cornerRadius: 2), with: ink, lineWidth: 1.3)
            var divider = Path()
            divider.move(to: CGPoint(x: 6, y: 2.8)); divider.addLine(to: CGPoint(x: 6, y: 13.2))
            context.stroke(divider, with: ink, lineWidth: 1.3)
        case .search:
            context.stroke(Path(ellipseIn: CGRect(x: 2.4, y: 2.4, width: 9.2, height: 9.2)), with: ink, lineWidth: 1.5)
            var handle = Path()
            handle.move(to: CGPoint(x: 10.5, y: 10.5)); handle.addLine(to: CGPoint(x: 14, y: 14))
            context.stroke(handle, with: ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .plus:
            var cross = Path()
            cross.move(to: CGPoint(x: 8, y: 3)); cross.addLine(to: CGPoint(x: 8, y: 13))
            cross.move(to: CGPoint(x: 3, y: 8)); cross.addLine(to: CGPoint(x: 13, y: 8))
            context.stroke(cross, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .gap:
            var corners = Path()
            corners.move(to: CGPoint(x: 2.5, y: 5.5)); corners.addLine(to: CGPoint(x: 2.5, y: 2.5)); corners.addLine(to: CGPoint(x: 5.5, y: 2.5))
            corners.move(to: CGPoint(x: 10.5, y: 2.5)); corners.addLine(to: CGPoint(x: 13.5, y: 2.5)); corners.addLine(to: CGPoint(x: 13.5, y: 5.5))
            corners.move(to: CGPoint(x: 13.5, y: 10.5)); corners.addLine(to: CGPoint(x: 13.5, y: 13.5)); corners.addLine(to: CGPoint(x: 10.5, y: 13.5))
            corners.move(to: CGPoint(x: 5.5, y: 13.5)); corners.addLine(to: CGPoint(x: 2.5, y: 13.5)); corners.addLine(to: CGPoint(x: 2.5, y: 10.5))
            context.stroke(corners, with: ink, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        case .check:
            var tick = Path()
            tick.move(to: CGPoint(x: 3.5, y: 8.5)); tick.addLine(to: CGPoint(x: 6.6, y: 11.5)); tick.addLine(to: CGPoint(x: 12.5, y: 4.8))
            context.stroke(tick, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

extension Tier {
    var icon: QuorumIcon { self == .quick ? .quick : .deep }
}

struct TierGlyph: View {
    let tier: Tier?
    var size: CGFloat = 12
    var color: Color = Ink.text3
    var pulsing = false

    var body: some View {
        if let tier { IconView(icon: tier.icon, size: size, color: color, pulsing: pulsing) }
    }
}
