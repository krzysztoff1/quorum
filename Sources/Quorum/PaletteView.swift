import SwiftUI
import QuorumCore

struct PaletteView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var filter = PaletteFilter.all
    @State private var index = 0
    @FocusState private var focused: Bool

    private var groups: [PaletteGroup] {
        let context = PaletteContext(selected: model.selectedThread, canGoDeeper: model.selectedThread.map { model.page(for: $0).canGoDeeper } ?? false,
                                     anyRunning: model.anyRunning)
        return Palette.search(query: query, filter: filter, threads: model.threads, context: context, now: Date(), calendar: .current)
    }

    private var items: [PaletteItem] { groups.flatMap(\.items) }
    private var current: PaletteItem? { items.indices.contains(index) ? items[index] : nil }
    private var preview: PalettePreview? { current.flatMap { Palette.preview(for: $0.action, threads: model.threads) } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.42).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                searchRow
                Ink.line.frame(height: 1)
                HStack(spacing: 0) {
                    results.frame(width: preview == nil ? 760 : 420)
                    if let preview {
                        Ink.line.frame(width: 1)
                        PreviewPane(preview: preview).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 380)
                keyHints
            }
            .frame(width: 760)
            .background(Ink.ink1, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.lineStrong))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.top, 90)
            .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onChange(of: filter) { _, _ in index = 0 }
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            IconView(icon: .search, size: 16, color: Ink.text3)
            TextField("Search questions, answers, sources — or ask something", text: $query)
                .textFieldStyle(.plain).font(Typeface.ui(16)).foregroundStyle(Ink.text1)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.tab) { filter = filter.next; return .handled }
                .onKeyPress(.return) { choose(); return .handled }
                .accessibilityLabel("Search")
            HStack(spacing: 4) {
                ForEach(PaletteFilter.allCases, id: \.self) { option in
                    Button { filter = option } label: {
                        Text(option.label).font(Typeface.ui(11.5, .medium))
                            .foregroundStyle(filter == option ? Ink.text1 : Ink.text3)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(filter == option ? Ink.ink4 : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 54)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.section.rawValue).font(Typeface.ui(11.5, .medium)).foregroundStyle(Ink.text3)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 5)
                        ForEach(group.items) { item in
                            let position = items.firstIndex { $0.id == item.id } ?? 0
                            PaletteRow(item: item, selected: position == index)
                                .id(item.id)
                                .onTapGesture { index = position; choose() }
                        }
                    }
                    if items.isEmpty { Text("Nothing matches.").font(Typeface.ui(13)).foregroundStyle(Ink.text3).padding(18) }
                }
                .padding(8)
            }
            .onChange(of: index) { _, _ in
                if let id = current?.id { proxy.scrollTo(id) }
            }
        }
    }

    private var keyHints: some View {
        HStack(spacing: 16) {
            hint(["↑", "↓"], "move"); hint(["⏎"], "open"); hint(["⇥"], "filter"); hint(["esc"], "close")
            Spacer()
        }
        .padding(.horizontal, 18).frame(height: 34)
        .overlay(alignment: .top) { Ink.line.frame(height: 1) }
    }

    private func hint(_ caps: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(caps, id: \.self) { KeyCap(label: $0) }
            Text(label).font(Typeface.ui(12)).foregroundStyle(Ink.text3)
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = min(max(index + delta, 0), items.count - 1)
    }

    private func choose() {
        guard let item = current else { return }
        model.perform(item.action)
    }

    private func close() { model.paletteOpen = false }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            TierGlyph(tier: item.tier, size: 12, color: Ink.text3).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Typeface.ui(13.5)).foregroundStyle(selected ? Ink.text1 : Ink.text2).lineLimit(1)
                if let snippet = item.snippet { Text(highlighted(snippet)).font(Typeface.ui(12)).lineLimit(1) }
                else if let detail = item.detail { Text(detail).font(Typeface.ui(12)).foregroundStyle(Ink.text3).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if let shortcut = item.shortcut { KeyCap(label: shortcut) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Ink.ink3 : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 1).fill(Ink.iris).frame(width: 2, height: 16) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func highlighted(_ snippet: PaletteSnippet) -> AttributedString {
        var out = AttributedString(snippet.text)
        out.foregroundColor = Ink.text3
        let characters = Array(snippet.text)
        guard snippet.match.lowerBound >= 0, snippet.match.upperBound <= characters.count else { return out }
        let before = String(characters[..<snippet.match.lowerBound])
        let hit = String(characters[snippet.match])
        let after = String(characters[snippet.match.upperBound...])
        var head = AttributedString(before); head.foregroundColor = Ink.text3
        var mid = AttributedString(hit); mid.foregroundColor = Ink.text1; mid.backgroundColor = Ink.irisWash
        var tail = AttributedString(after); tail.foregroundColor = Ink.text3
        return head + mid + tail
    }
}

private struct PreviewPane: View {
    let preview: PalettePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TierGlyph(tier: preview.tier, size: 13, color: preview.tier == .deep ? Ink.iris : Ink.text2)
                Text(preview.tier?.displayName ?? "").font(Typeface.ui(12, .medium)).foregroundStyle(Ink.text2)
            }
            Text(preview.title).font(Typeface.ui(17, .semibold)).foregroundStyle(Ink.text1).fixedSize(horizontal: false, vertical: true)
            Text(preview.trustLine).font(Typeface.ui(12)).foregroundStyle(Ink.text3)
            Text(preview.lead).font(Typeface.read(15)).foregroundStyle(Ink.claimText).lineSpacing(4).lineLimit(9)
            if !preview.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Follow-ups").font(Typeface.ui(11.5, .medium)).foregroundStyle(Ink.text3)
                    ForEach(preview.followUps, id: \.self) { Text($0).font(Typeface.ui(12.5)).foregroundStyle(Ink.text2).lineLimit(1) }
                }
            }
            Spacer()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
