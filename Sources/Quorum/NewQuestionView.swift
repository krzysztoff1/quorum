import SwiftUI
import QuorumCore

struct NewQuestionView: View {
    @Bindable var model: AppModel

    private var composer: ComposerModel { model.composer }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(crumb: "New question") {
                TopBarButton(icon: .search, title: "Search", key: "⌘K") { model.dispatch(.palette) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch composer.flow.step {
                    case .drafting: DraftingView(model: model)
                    case .scoping: ScopingWaitView(flow: composer.flow)
                    case .clarifying: ClarifyingView(model: model)
                    case .confirming: ConfirmingView(model: model)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 56).padding(.bottom, 56)
                .frame(maxWidth: .infinity)
                .animation(Motion.reveal, value: composer.flow.step)
            }
            KeyBar(hints: hints, trailing: "Runs on your Claude subscription")
        }
        .background(Ink.ink1)
    }

    private var hints: [KeyHint] {
        switch composer.flow.step {
        case .drafting: return [KeyHint(caps: ["⏎"], label: "ask"), KeyHint(caps: ["⇥"], label: "Quick / Deep"), KeyHint(caps: ["⌘K"], label: "search")]
        case .scoping: return [KeyHint(caps: ["esc"], label: "back to your words")]
        case .clarifying:
            return [KeyHint(caps: ["1", "4"], label: "pick"), KeyHint(caps: ["⏎"], label: "continue"), KeyHint(caps: ["esc"], label: "back to your words")]
        case .confirming:
            return [KeyHint(caps: ["E"], label: "edit question"), KeyHint(caps: ["⇥"], label: "Quick / Deep"),
                    KeyHint(caps: ["⌘⏎"], label: "start"), KeyHint(caps: ["esc"], label: "back to your words")]
        }
    }
}

private struct AskedRow: View {
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(letter: "KD")
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(Typeface.ui(17)).foregroundStyle(Ink.text1).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(Typeface.ui(12.5)).foregroundStyle(Ink.text3) }
            }
        }
        .padding(.bottom, 28)
    }
}

struct Avatar: View {
    let letter: String

    var body: some View {
        Text(letter).font(Typeface.ui(10.5, .semibold)).foregroundStyle(Ink.text2)
            .frame(width: 28, height: 28)
            .background(Ink.ink3, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct DraftingView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    private var composer: ComposerModel { model.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let reason = model.engineRefusal { Notice(text: reason, tone: Ink.amber) }
            Text("What do you want to know?").font(Typeface.read(30)).foregroundStyle(Ink.text1)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if composer.flow.draft.isEmpty {
                        Text("Ask it the way you would ask a colleague.").font(Typeface.ui(17)).foregroundStyle(Ink.text4)
                            .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { composer.flow.draft }, set: { composer.flow.draft = $0 }))
                        .font(Typeface.ui(17)).foregroundStyle(Ink.text1)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 96, maxHeight: 220)
                        .accessibilityLabel("Your question")
                }
                HStack(spacing: 10) {
                    TierToggle(tier: composer.flow.tier) { composer.toggleTier() }
                    Text(composer.flow.tier == .quick ? "About 3 minutes" : "15–25 minutes in the background")
                        .font(Typeface.ui(12)).foregroundStyle(Ink.text3)
                    Spacer()
                    PrimaryButton(title: "Ask", key: "⏎", enabled: composer.canAsk) { composer.ask() }
                }
                .padding(.top, 6)
            }
            .padding(16)
            .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Ink.irisLine : Ink.line))
            .animation(Motion.hover, value: focused)
        }
        .onAppear { focused = true }
        .onChange(of: composer.focusRequest) { _, _ in focused = true }
    }
}

struct TierToggle: View {
    let tier: Tier
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tier.allCases, id: \.self) { option in
                Button { if tier != option { toggle() } } label: {
                    HStack(spacing: 6) {
                        TierGlyph(tier: option, size: 12, color: tier == option ? (option == .deep ? Ink.iris : Ink.text1) : Ink.text3)
                        Text(option.displayName)
                    }
                    .font(Typeface.ui(12.5, .medium))
                    .foregroundStyle(tier == option ? Ink.text1 : Ink.text3)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(tier == option ? Ink.ink4 : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.displayName)\(tier == option ? ", selected" : "")")
            }
            KeyCap(label: "⇥").padding(.leading, 6)
        }
        .padding(2)
        .background(Ink.ink1, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
        .animation(Motion.hover, value: tier)
    }
}

struct PrimaryButton: View {
    let title: String
    var key: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(Typeface.ui(13.5, .semibold))
                if let key {
                    Text(key).font(Typeface.ui(11, .medium))
                        .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                        .background(Ink.ink0.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(Ink.ink0)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Ink.iris.opacity(!enabled ? 0.3 : hovering ? 1 : 0.92), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Typeface.ui(13.5, .medium)).foregroundStyle(hovering ? Ink.text1 : Ink.text2)
                .padding(.horizontal, 12).frame(height: 34)
                .background(hovering ? Ink.ink3 : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

struct Notice: View {
    let text: String
    let tone: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(icon: .gap, size: 14, color: tone).padding(.top, 2)
            Text(text).font(Typeface.ui(13)).foregroundStyle(Ink.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tone.opacity(0.25)))
    }
}

private struct ScopingWaitView: View {
    let flow: ScopingFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskedRow(text: flow.asked, detail: flow.tier.displayName)
            HStack(spacing: 10) {
                TierGlyph(tier: .quick, size: 14, color: Ink.iris, pulsing: true)
                Text("Reading your question…").font(Typeface.ui(13.5)).foregroundStyle(Ink.text3)
            }
            .padding(.leading, 42)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClarifyingView: View {
    @Bindable var model: AppModel
    @FocusState private var ownFocused: Bool

    private var flow: ScopingFlow { model.composer.flow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskedRow(text: flow.asked, detail: flow.tier.displayName)
            Text(flow.questions.count == 1 ? "One question, so Quorum aims at what you need:" : "A couple of questions, so Quorum aims at what you need:")
                .font(Typeface.ui(15)).foregroundStyle(Ink.text2).padding(.leading, 42).padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(flow.questions.enumerated()), id: \.element.id) { index, question in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(question.text).font(Typeface.ui(14.5, .semibold)).foregroundStyle(Ink.text1)
                            if question.multi { Text("pick any").font(Typeface.ui(12)).foregroundStyle(Ink.text4) }
                        }
                        FlowLayout(spacing: 8) {
                            ForEach(Array(question.options.enumerated()), id: \.element.id) { option, item in
                                OptionChip(key: ScopeKeys.label(question: index, option: option), label: item.label,
                                           selected: flow.picked(question: index).contains(item.id)) {
                                    model.composer.pick(question: index, option: option)
                                }
                            }
                        }
                    }
                }
                Divider().overlay(Ink.line)
                TextField("…or say it in your own words", text: Binding(get: { model.composer.flow.ownWords }, set: { model.composer.flow.ownWords = $0 }))
                    .textFieldStyle(.plain).font(Typeface.ui(14)).foregroundStyle(Ink.text1)
                    .focused($ownFocused)
                    .onSubmit { model.composer.continueClarifying() }
            }
            .padding(20)
            .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
            .padding(.leading, 42)
            HStack(spacing: 8) {
                PrimaryButton(title: "Continue", key: "⏎") { model.composer.continueClarifying() }
                GhostButton(title: "Research my original wording") { model.composer.startAsWritten() }
            }
            .padding(.leading, 42).padding(.top, 18)
        }
    }
}

private struct OptionChip: View {
    let key: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key).font(Typeface.ui(11, .semibold)).foregroundStyle(selected ? Ink.iris : Ink.text3)
                Text(label).font(Typeface.ui(13.5)).foregroundStyle(selected ? Ink.text1 : Ink.text2)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(selected ? Ink.irisWash : hovering ? Ink.ink3 : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Ink.irisLine : Ink.lineStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: selected)
        .accessibilityLabel("\(label)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

private struct ConfirmingView: View {
    @Bindable var model: AppModel
    @FocusState private var editing: Bool

    private var flow: ScopingFlow { model.composer.flow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskedRow(text: flow.asked)
            if let reason = flow.fallbackReason { Notice(text: "Quorum couldn't tighten the question (\(reason)). It will research it as written.", tone: Ink.amber).padding(.bottom, 18).padding(.leading, 42) }
            HStack {
                Text("Quorum will research").font(Typeface.ui(12.5)).foregroundStyle(Ink.text3)
                Spacer()
                if flow.editingResolved {
                    TopBarButton(icon: nil, title: "Done", key: "⏎") { model.composer.commitResolvedEdit() }
                } else {
                    TopBarButton(icon: nil, title: "Edit", key: "E") { model.composer.beginEditingResolved() }
                }
            }
            .padding(.leading, 42).padding(.bottom, 8)
            Group {
                if flow.editingResolved {
                    TextEditor(text: Binding(get: { model.composer.flow.resolvedDraft }, set: { model.composer.flow.resolvedDraft = $0 }))
                        .font(Typeface.read(21)).foregroundStyle(Ink.text1).scrollContentBackground(.hidden)
                        .focused($editing).frame(minHeight: 90)
                        .onKeyPress(.return) { model.composer.commitResolvedEdit(); return .handled }
                        .onKeyPress(.escape) { model.composer.cancelResolvedEdit(); return .handled }
                        .onAppear { editing = true }
                } else {
                    Text(flow.resolvedQuestion).font(Typeface.read(21)).foregroundStyle(Ink.text1)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 16).padding(.vertical, 4)
            .overlay(alignment: .leading) { Ink.iris.opacity(0.7).frame(width: 2) }
            .padding(.leading, 42).padding(.bottom, 22)
            HStack(spacing: 10) {
                ForEach(Tier.allCases, id: \.self) { tier in TierCard(tier: tier, flow: flow) { if flow.tier != tier { model.composer.toggleTier() } } }
            }
            .padding(.leading, 42)
            HStack(spacing: 8) {
                PrimaryButton(title: "Start \(flow.tier.displayName) research", key: "⌘⏎") { model.composer.start() }
                GhostButton(title: "Research my original wording") { model.composer.startAsWritten() }
                Spacer()
                Text("You can close the window once it starts.").font(Typeface.ui(12)).foregroundStyle(Ink.text4)
            }
            .padding(.leading, 42).padding(.top, 18)
        }
    }
}

private struct TierCard: View {
    let tier: Tier
    let flow: ScopingFlow
    let action: () -> Void
    @State private var hovering = false

    private var selected: Bool { flow.tier == tier }
    private var suggested: Bool { flow.brief?.suggestedTier == tier }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TierGlyph(tier: tier, size: 13, color: selected && tier == .deep ? Ink.iris : Ink.text2)
                    Text(tier.displayName).font(Typeface.ui(14.5, .semibold)).foregroundStyle(Ink.text1)
                    if suggested { Text(flow.tierReason.isEmpty ? "suggested" : "suggested — \(flow.tierReason)").font(Typeface.ui(12)).foregroundStyle(Ink.text3).lineLimit(1) }
                    Spacer()
                }
                Text(tier == .quick
                     ? "About 3 minutes. Two or three angles, one pass. Every quote still checked."
                     : "15–25 minutes in the background. More angles, critics check the draft, gaps get a second round.")
                    .font(Typeface.ui(12.5)).foregroundStyle(Ink.text3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Ink.irisWash : hovering ? Ink.ink2 : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Ink.irisLine : Ink.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: selected)
        .accessibilityLabel("\(tier.displayName)\(selected ? ", selected" : "")")
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
