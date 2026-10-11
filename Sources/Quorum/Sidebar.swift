import SwiftUI
import QuorumCore

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        let sections = model.sections
        let order = model.order
        let selection = model.selection
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { model.dispatch(.toggleSidebar) } label: { IconView(icon: .sidebar, size: 16, color: Ink.text3) }
                    .buttonStyle(.plain).help("Hide sidebar (⌘\\)").accessibilityLabel("Hide sidebar")
            }
            .padding(.horizontal, 14).frame(height: 40)
            AskButton { model.dispatch(.newQuestion) }
                .padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        SectionTitle(title: section.title, count: section.title == "Running" ? section.rows.count : nil)
                        ForEach(section.rows) { row in
                            InboxRowView(row: row, selected: selection == .question(row.id), position: order.firstIndex(of: row.id).map { $0 + 1 })
                                .id("\(row.id)|\(row.state)|\(row.unread)")
                                .onTapGesture { model.select(question: row.id) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { model.select(question: row.id) }
                                .accessibilityAction(named: "Move to Trash") { if let thread = model.thread(row.id) { model.trash(thread) } }
                                .contextMenu { menu(for: row) }
                        }
                    }
                    if !model.unreadableRows.isEmpty {
                        SectionTitle(title: "Couldn't open", count: model.unreadableRows.count)
                        ForEach(model.unreadableRows) { UnreadableRowView(row: $0) }
                    }
                    if model.threads.isEmpty && model.unreadableRows.isEmpty { EmptyInbox() }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            BrainFooter(model: model)
        }
        .frame(width: 252)
        .background(Ink.ink0)
        .overlay(alignment: .trailing) { Ink.line.frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions")
    }

    @ViewBuilder private func menu(for row: InboxRow) -> some View {
        if let thread = model.thread(row.id) {
            Button("Copy as Markdown") { model.copyMarkdown(thread) }
            Button("Open in Claude Code") { model.openInClaudeCode(thread) }
            Button("Show in Finder") { model.reveal(thread) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(thread) }
        }
    }
}

private struct AskButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconView(icon: .plus, size: 14, color: Ink.text2)
                Text("Ask a question").font(Typeface.ui(13.5)).foregroundStyle(Ink.text1)
                Spacer()
                KeyCap(label: "N")
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(hovering ? Ink.ink3 : Ink.ink2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("Ask a question")
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count { Text("\(count)").foregroundStyle(Ink.text4) }
        }
        .font(Typeface.ui(12, .medium)).foregroundStyle(Ink.text3)
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct UnreadableRowView: View {
    let row: UnreadableRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title).font(Typeface.ui(13.5)).foregroundStyle(Ink.text3).lineLimit(1).truncationMode(.middle)
            Text(row.reason).font(Typeface.ui(11.5)).foregroundStyle(Ink.amber.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .help(row.explanation)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.reason)")
        .accessibilityHint(row.explanation)
    }
}

struct InboxRowView: View {
    let row: InboxRow
    let selected: Bool
    let position: Int?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Leading(row: row).frame(width: 14, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title.isEmpty ? "Untitled" : row.title)
                        .font(Typeface.ui(13.5, row.unread ? .semibold : .regular))
                        .foregroundStyle(selected || row.unread ? Ink.text1 : Ink.text2)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(row.when).font(Typeface.ui(11.5)).foregroundStyle(Ink.text3).monospacedDigit()
                }
                HStack(spacing: 5) {
                    if let tier = row.tier { Text(tier.displayName) }
                    ForEach(Array(row.parts.enumerated()), id: \.offset) { _, part in
                        Text("·")
                        Text(part).lineLimit(1)
                    }
                }
                .font(Typeface.ui(11.5)).foregroundStyle(subtitleColor)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Ink.ink3 : hovering ? Ink.ink2 : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 1).fill(Ink.iris).frame(width: 2, height: 18) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var subtitleColor: Color {
        switch row.state {
        case .failed: return Ink.rose
        case .stopped, .partial: return Ink.amber.opacity(0.85)
        default: return Ink.text3
        }
    }

    private var accessibilityText: String {
        let state = ([row.tier?.displayName].compactMap { $0 } + row.parts).joined(separator: ", ")
        return "\(row.title), \(state)\(row.unread ? ", unread" : "")"
    }

    private struct Leading: View {
        let row: InboxRow

        var body: some View {
            switch row.state {
            case .running:
                TierGlyph(tier: row.tier ?? .quick, size: 14, color: Ink.iris, pulsing: true)
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Ink.rose)
            case .stopped, .partial:
                IconView(icon: .gap, size: 13, color: Ink.amber)
            case .answered:
                if row.unread { Circle().fill(Ink.amber).frame(width: 7, height: 7) } else { TierGlyph(tier: row.tier, size: 12, color: Ink.text4) }
            }
        }
    }
}

private struct EmptyInbox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No questions yet").font(Typeface.ui(13, .medium)).foregroundStyle(Ink.text2)
            Text("Ask one and the answer lands here.").font(Typeface.ui(12)).foregroundStyle(Ink.text3)
        }
        .padding(.horizontal, 10).padding(.top, 14)
    }
}

private struct BrainFooter: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button { model.chooseBrainFolder() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Ink.text3)
                Text(model.brainName).font(Typeface.ui(12.5)).foregroundStyle(Ink.text2).lineLimit(1)
                Spacer()
                if model.unreadCount > 0 { Text("\(model.unreadCount) new").font(Typeface.ui(11.5)).foregroundStyle(Ink.amber) }
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(hovering ? Ink.ink2 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
        .help("Choose brain folder")
        .accessibilityLabel("Brain folder \(model.brainName)")
    }
}
