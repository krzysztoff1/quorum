import SwiftUI
import QuorumCore

struct KeyCap: View {
    let label: String
    var wide = false

    var body: some View {
        Text(label)
            .font(Typeface.ui(11, .medium))
            .foregroundStyle(Ink.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(Ink.ink3, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.line))
            .accessibilityHidden(true)
    }
}

struct KeyHint: Identifiable {
    var id: String { caps.joined() + label }
    let caps: [String]
    let label: String
}

struct KeyBar: View {
    let hints: [KeyHint]
    var trailing: String = ""

    var body: some View {
        HStack(spacing: 18) {
            ForEach(hints) { hint in
                HStack(spacing: 6) {
                    ForEach(hint.caps, id: \.self) { KeyCap(label: $0) }
                    Text(hint.label).font(Typeface.ui(12)).foregroundStyle(Ink.text3)
                }
            }
            Spacer(minLength: 12)
            Text(trailing).font(Typeface.ui(12)).foregroundStyle(Ink.text4).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 22)
        .frame(height: 34)
        .background(Ink.ink1)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }
}

struct TopBarButton: View {
    let icon: QuorumIcon?
    let title: String
    var key: String?
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { IconView(icon: icon, size: 14, color: active ? Ink.iris : Ink.text2) }
                Text(title).font(Typeface.ui(12.5, .medium))
                if let key { KeyCap(label: key) }
            }
            .foregroundStyle(active ? Ink.iris : Ink.text2)
            .padding(.horizontal, 9).frame(height: 28)
            .background(hovering || active ? Ink.ink3 : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Ink.irisLine : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel(title)
    }
}

struct TopBar<Trailing: View>: View {
    let crumb: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text("Questions").foregroundStyle(Ink.text3)
            Text("/").foregroundStyle(Ink.text4)
            Text(crumb).foregroundStyle(Ink.text1).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            trailing()
        }
        .font(Typeface.ui(13.5, .medium))
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Ink.line.frame(height: 1) }
    }
}

enum Motion {
    static let hover = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.09)
    static let reveal = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
    static let panel = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.22)
}

struct FocusRing: ViewModifier {
    let active: Bool
    var radius: CGFloat = 6

    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Ink.iris.opacity(active ? 0.9 : 0), lineWidth: 1.5))
    }
}

extension View {
    func focusRing(_ active: Bool, radius: CGFloat = 6) -> some View { modifier(FocusRing(active: active, radius: radius)) }
}
