import SwiftUI
import AppKit
import QuorumCore

/// The canvas's own paint: a surface a shade darker than the window so the cards read as plates on a
/// board, and a dot grid faint enough to give panning a spatial reference without competing with a wire.
enum CanvasSurface {
    static let background = Color(nsColor: dynamic(
        dark: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.094, alpha: 1),
        light: NSColor(srgbRed: 0.962, green: 0.963, blue: 0.972, alpha: 1)))

    static let grid = Color(nsColor: dynamic(
        dark: NSColor(white: 1, alpha: 0.07),
        light: NSColor(white: 0, alpha: 0.07)))

    static let gridSpacing: CGFloat = 18
    static let dotRadius: CGFloat = 1

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// The one place a style token becomes paint. Everything that draws a run — the canvas, the sidebar badges,
/// the digest — asks `NodeStyle` what something looks like and lands here; nothing else is allowed a
/// second opinion about what "complete" is coloured.
extension StyleTint {
    var color: Color {
        switch self {
        case .accent:  return .accentColor
        case .blue:    return .blue
        case .teal:    return .teal
        case .green:   return .green
        case .yellow:  return .yellow
        case .orange:  return .orange
        case .red:     return .red
        case .purple:  return .purple
        case .pink:    return .pink
        case .neutral: return .secondary
        }
    }
}

extension NodeStyle {
    var color: Color { tint.color }
}

/// A style, drawn. Work in flight spins rather than showing a glyph, which is the one branch every surface
/// used to write out for itself.
struct NodeStyleIcon: View {
    let style: NodeStyle
    var tinted = true

    var body: some View {
        if style.showsProgress {
            ProgressView().controlSize(.mini)
        } else if tinted {
            Image(systemName: style.icon).foregroundStyle(style.color)
        } else {
            Image(systemName: style.icon)
        }
    }
}
