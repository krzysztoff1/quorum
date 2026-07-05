import SwiftUI
import QuorumCore

/// One row in the quick switcher: a chat, note, or command. `action` performs it (usually flips the
/// sidebar selection); the palette dismisses itself right after.
struct QuickSwitchItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void
}

/// The ⌘K global quick switcher — one search box over every chat, note, and command. Type to filter
/// (ranked by `QuickSwitch`), ↑/↓ to move, ↩ to open the highlighted row, esc to close.
struct QuickSwitchView: View {
    let items: [QuickSwitchItem]
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [QuickSwitchItem] {
        QuickSwitch.rankedIndices(query, items.map(\.title)).map { items[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats, notes, and commands…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocused)
                    .onSubmit(activateHighlighted)
            }
            .padding(12)
            Divider()

            if results.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == highlighted)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(item) }
                            }
                        }
                    }
                    .onChange(of: highlighted) { _, i in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(i, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 640, height: 440)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand { onDismiss() }
        .onAppear { searchFocused = true }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    private func activateHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ item: QuickSwitchItem) {
        item.action()
        onDismiss()
    }

    private func row(_ item: QuickSwitchItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.subtitle).font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear)
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
}
