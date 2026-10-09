import SwiftUI
import AppKit
import QuorumCore

enum Ink {
    static let ink0 = Color(hex: 0x0F1015)
    static let ink1 = Color(hex: 0x14161C)
    static let ink2 = Color(hex: 0x1A1D24)
    static let ink3 = Color(hex: 0x22262E)
    static let line = Color(red: 206 / 255, green: 214 / 255, blue: 1).opacity(0.075)
    static let lineStrong = Color(red: 206 / 255, green: 214 / 255, blue: 1).opacity(0.13)
    static let text1 = Color(hex: 0xE8EAF0)
    static let text2 = Color(hex: 0xA4A9B6)
    static let text3 = Color(hex: 0x6D7280)
    static let text4 = Color(hex: 0x4B4F5A)
    static let claimText = Color(hex: 0xD9DCE4)
    static let iris = Color(hex: 0xA9B3FF)
    static let irisWash = Color(hex: 0xA9B3FF).opacity(0.07)
    static let jade = Color(hex: 0x7FD4AF)
    static let jadeWash = Color(hex: 0x7FD4AF).opacity(0.13)
    static let amber = Color(hex: 0xEBB866)
    static let amberWash = Color(hex: 0xEBB866).opacity(0.13)
    static let vizConfirmed = Color(hex: 0x42AB80)
    static let vizUnconfirmed = Color(hex: 0xC2862A)
}

enum Typeface {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func read(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static let title = ui(27, .semibold)
    static let lead = read(21)
    static let bodyRead = read(16.5)
    static let bodyUI = ui(13.5)
    static let meta = ui(12.5)
    static let small = ui(11.5, .medium)
    static let chip = ui(10.5, .semibold)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Hatch {
    static func image(_ stripe: NSColor, background: NSColor = .clear) -> NSImage {
        let size = NSSize(width: 6, height: 6)
        let image = NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            stripe.setStroke()
            for offset in stride(from: -6.0, through: 12.0, by: 4.4) {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.move(to: NSPoint(x: offset, y: 0))
                path.line(to: NSPoint(x: offset + 6, y: 6))
                path.stroke()
            }
            return true
        }
        return image
    }

    static let unverified = ImagePaint(image: Image(nsImage: image(NSColor(Ink.vizUnconfirmed))), scale: 1)
    static let estimate = ImagePaint(image: Image(nsImage: image(NSColor(Ink.text3))), scale: 1)
}

extension DatumMark {
    var fill: AnyShapeStyle {
        switch self {
        case .verified: return AnyShapeStyle(Ink.vizConfirmed)
        case .close: return AnyShapeStyle(Ink.vizConfirmed.opacity(0.42))
        case .estimate: return AnyShapeStyle(Hatch.estimate)
        case .unverified: return AnyShapeStyle(Hatch.unverified)
        }
    }

    var outline: Color? {
        switch self {
        case .unverified: return Ink.vizUnconfirmed
        case .estimate: return Ink.text3
        default: return nil
        }
    }

    var legend: String {
        switch self {
        case .verified: return "Quote verified"
        case .close: return "Close match"
        case .estimate: return "The run's estimate"
        case .unverified: return "Not in its quote"
        }
    }

    var valueColor: Color { self == .unverified ? Ink.amber : Ink.text1 }
}

extension CitationTier {
    var chipForeground: Color {
        switch self {
        case .supported, .close: return Ink.jade
        case .unsupported: return Ink.amber
        case .unresolved: return Ink.text3
        }
    }

    var chipBackground: Color {
        switch self {
        case .supported: return Ink.jadeWash
        case .close: return Ink.jade.opacity(0.06)
        case .unsupported: return Ink.amberWash
        case .unresolved: return .clear
        }
    }
}

struct MarkSwatch: View {
    let mark: DatumMark
    var width: CGFloat = 16
    var height: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(mark.fill)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(mark.outline ?? .clear, lineWidth: 1))
            .frame(width: width, height: height)
    }
}

struct ChipLabel: View {
    let number: Int
    let tier: CitationTier
    var hot = false

    var body: some View {
        Text("\(number)\(tier.mark)")
            .font(Typeface.chip)
            .monospacedDigit()
            .foregroundStyle(tier.chipForeground)
            .padding(.horizontal, 4)
            .frame(minWidth: 17, minHeight: 17)
            .background(tier.chipBackground, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(hot ? tier.chipForeground : (tier == .close ? Ink.jade.opacity(0.38) : .clear),
                              style: StrokeStyle(lineWidth: 1, dash: tier == .unresolved ? [2, 2] : [])))
    }
}

struct ConflictGlyph: View {
    var body: some View {
        Canvas { context, size in
            let top = Path(roundedRect: CGRect(x: 0, y: size.height * 0.22, width: size.width * 0.62, height: 2), cornerRadius: 1)
            let bottom = Path(roundedRect: CGRect(x: size.width * 0.38, y: size.height * 0.66, width: size.width * 0.62, height: 2), cornerRadius: 1)
            context.fill(top, with: .color(Ink.amber))
            context.fill(bottom, with: .color(Ink.amber))
        }
        .frame(width: 12, height: 12)
    }
}

struct ObjectionGlyph: View {
    var body: some View {
        Canvas { context, size in
            var bubble = Path(roundedRect: CGRect(x: 0.75, y: 0.75, width: size.width - 1.5, height: size.height * 0.72), cornerRadius: 2.5)
            bubble.move(to: CGPoint(x: size.width * 0.3, y: size.height * 0.72 + 0.75))
            bubble.addLine(to: CGPoint(x: size.width * 0.25, y: size.height - 0.75))
            bubble.addLine(to: CGPoint(x: size.width * 0.5, y: size.height * 0.72 + 0.75))
            context.stroke(bubble, with: .color(Ink.amber), lineWidth: 1.3)
            context.stroke(Path { $0.move(to: CGPoint(x: size.width * 0.3, y: size.height * 0.38)); $0.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.38)) },
                           with: .color(Ink.amber), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .frame(width: 12, height: 12)
    }
}

struct WarningGlyph: View {
    var color = Ink.amber

    var body: some View {
        Canvas { context, size in
            var triangle = Path()
            triangle.move(to: CGPoint(x: size.width / 2, y: 1))
            triangle.addLine(to: CGPoint(x: size.width - 1, y: size.height - 1.5))
            triangle.addLine(to: CGPoint(x: 1, y: size.height - 1.5))
            triangle.closeSubpath()
            context.stroke(triangle, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            context.fill(Path(CGRect(x: size.width / 2 - 0.65, y: size.height * 0.36, width: 1.3, height: size.height * 0.28)), with: .color(color))
            context.fill(Path(ellipseIn: CGRect(x: size.width / 2 - 0.8, y: size.height * 0.7, width: 1.6, height: 1.6)), with: .color(color))
        }
        .frame(width: 12, height: 12)
    }
}

struct GutterRule: View {
    let strength: ClaimStrength
    var focused = false

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 1, y: 0))
                path.addLine(to: CGPoint(x: 1, y: geometry.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: strength == .solid ? [] : [2, 4]))
        }
        .frame(width: 2)
        .opacity(strength == .solid || focused ? 1 : 0.7)
    }

    private var color: Color {
        if focused { return Ink.iris }
        switch strength {
        case .solid: return Ink.text4
        case .shaky: return Ink.amber
        case .unchecked: return Ink.text3
        }
    }
}
