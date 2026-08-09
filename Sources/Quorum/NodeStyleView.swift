import SwiftUI
import QuorumCore

/// The one place a style token becomes paint. Everything that draws a run — the canvas, the sidebar badges,
/// the timeline lanes, the digest — asks `NodeStyle` what something looks like and lands here; nothing else
/// is allowed a second opinion about what "complete" is coloured.
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
