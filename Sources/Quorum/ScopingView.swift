import SwiftUI
import AppKit
import QuorumCore

struct ScopingView: View {
    @Bindable var model: AppModel
    @State private var flow = ScopingFlow()
    @State private var editingResolved = false
    @State private var resolvedDraft = ""
    @State private var scopeToken = UUID()
    @State private var keyMonitor: Any?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case question, ownWords, resolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if flow.step == .drafting {
                composer
            } else {
                askedRow
                stepContent
            }
        }
        .onAppear {
            focus = .question
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handle(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: flow.step) { _, step in
            DispatchQueue.main.async { focus = step == .drafting ? .question : nil }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Explore every angle", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.bold())
                if flow.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Ask one big question — Quorum checks what you mean, researches it from many angles at once, then merges the findings into one answer.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("What do you want to explore?", text: $flow.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.title3).lineLimit(3...10)
                .focused($focus, equals: .question)
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    ask()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    flow.toggleTier()
                    return .handled
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))

            tierPicker

            Button(action: ask) {
                Label("Ask", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canAsk)
        }
    }

    private var tierPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Depth").font(.headline)
                Spacer()
                Text("⇥ to switch").font(.caption).foregroundStyle(.tertiary)
            }
            Picker("Depth", selection: tierBinding) {
                ForEach(Tier.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(AppModel.tierBlurb(flow.tier)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tierBinding: Binding<Tier> {
        Binding(get: { flow.tier }, set: { if $0 != flow.tier { flow.toggleTier() } })
    }

    private var canAsk: Bool { model.canRun && !flow.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func ask() {
        guard canAsk, let request = flow.submit() else { return }
        requestScope(request)
    }

    private func requestScope(_ request: ScopeRequest) {
        let token = UUID()
        scopeToken = token
        Task {
            let result = await model.scope(request)
            guard scopeToken == token, flow.step == .scoping else { return }
            switch result {
            case .success(let reply): flow.receive(reply)
            case .failure(let failure): flow.fail(failure)
            }
        }
    }

    private var askedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.asked).font(.body).fixedSize(horizontal: false, vertical: true)
                Text(flow.tier.displayName).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch flow.step {
        case .scoping: scoping
        case .clarifying: clarifying
        case .confirming: confirming
        case .drafting: EmptyView()
        }
    }

    private var scoping: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading your question…").font(.callout).foregroundStyle(.secondary)
            Spacer()
            hint("esc edit")
        }
    }

    // MARK: Clarifying

    private var clarifying: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(flow.questions.enumerated()), id: \.offset) { index, asking in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(asking.text).font(.subheadline.weight(.semibold))
                            if asking.multi { Text("pick any").font(.caption).foregroundStyle(.tertiary) }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(Array(asking.options.enumerated()), id: \.offset) { optionIndex, option in
                                optionChip(question: index, option: optionIndex, label: option.label)
                            }
                        }
                    }
                }
                TextField("…or say it in your own words", text: $flow.ownWords)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .ownWords)
                    .onKeyPress(.return, phases: .down) { _ in
                        continueClarifying()
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        focus = nil
                        return .handled
                    }
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Divider() }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Button { continueClarifying() } label: { Text("Continue") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Research my original wording") { startAsWritten() }
                    .buttonStyle(.bordered).controlSize(.large)
                Spacer()
                hint("keys pick · ⏎ continue · esc back to your words")
            }
        }
    }

    private func optionChip(question: Int, option: Int, label: String) -> some View {
        let selected = flow.picked(question: question).contains(flow.questions[question].options[option].id)
        return Button { flow.pick(question: question, option: option) } label: {
            HStack(spacing: 8) {
                Text(ScopeKeys.label(question: question, option: option))
                    .font(.caption.monospaced().weight(.semibold))
                    .frame(width: 18, height: 18)
                    .background(selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                Text(label).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func continueClarifying() {
        if let request = flow.continueClarifying() { requestScope(request) }
    }

    // MARK: Confirming

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let reason = flow.fallbackReason { fallbackBanner(reason) }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Quorum will research").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { beginEditingResolved() } label: {
                        HStack(spacing: 4) { Text("Edit"); keycap("E") }
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
                resolvedText
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Tier.allCases, id: \.self) { tierRow($0) }
            }

            HStack(spacing: 10) {
                Button { start() } label: { Text("Start \(flow.tier.displayName) research") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Research my original wording") { startAsWritten() }
                    .buttonStyle(.bordered).controlSize(.large)
                Spacer()
                hint("⏎ start · ⇥ Quick / Deep · E edit · esc back to your words")
            }
        }
    }

    @ViewBuilder private var resolvedText: some View {
        if editingResolved {
            TextField("The question to research", text: $resolvedDraft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 19, design: .serif)).lineLimit(2...8)
                .focused($focus, equals: .resolved)
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    commitResolvedEdit()
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    editingResolved = false
                    focus = nil
                    return .handled
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
        } else {
            Text(flow.resolvedQuestion)
                .font(.system(size: 19, design: .serif)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }

    private func tierRow(_ tier: Tier) -> some View {
        let selected = flow.tier == tier
        let suggested = flow.brief?.suggestedTier == tier
        return Button { if flow.tier != tier { flow.toggleTier() } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tier.displayName).font(.callout.weight(.semibold))
                        if suggested && !flow.tierReason.isEmpty { Text("suggested").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(AppModel.tierBlurb(tier)).font(.caption).foregroundStyle(.secondary)
                    if suggested && !flow.tierReason.isEmpty {
                        Text(flow.tierReason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func fallbackBanner(_ reason: String) -> some View {
        Label {
            Text("Quorum couldn't check this question (\(reason)). It will research your words as written.").font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Keys and actions

    private func handle(_ event: NSEvent) -> Bool {
        guard flow.step != .drafting, !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch flow.step {
        case .scoping:
            guard event.keyCode == Self.escapeKey else { return false }
            scopeToken = UUID()
            flow.edit()
            return true
        case .clarifying:
            if event.keyCode == Self.returnKey { continueClarifying(); return true }
            if event.keyCode == Self.escapeKey { flow.edit(); return true }
            if plain, let key = characters.first, let target = ScopeKeys.target(for: key, questions: flow.questions.count) {
                flow.pick(question: target.question, option: target.option)
                return true
            }
        case .confirming:
            if event.keyCode == Self.returnKey { start(); return true }
            if event.keyCode == Self.escapeKey { flow.edit(); return true }
            if event.keyCode == Self.tabKey { flow.toggleTier(); return true }
            if plain, characters.lowercased() == "e" { beginEditingResolved(); return true }
        case .drafting:
            break
        }
        return false
    }

    private static let returnKey: UInt16 = 36
    private static let escapeKey: UInt16 = 53
    private static let tabKey: UInt16 = 48

    private func beginEditingResolved() {
        resolvedDraft = flow.resolvedQuestion
        editingResolved = true
        DispatchQueue.main.async { focus = .resolved }
    }

    private func commitResolvedEdit() {
        let text = resolvedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { flow.editResolved(text) }
        editingResolved = false
        focus = nil
    }

    private func start() {
        guard let start = flow.confirm() else { return }
        model.startRun(start)
        flow.reset()
    }

    private func startAsWritten() {
        guard let start = flow.runAsWritten() else { return }
        model.startRun(start)
        flow.reset()
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.caption2.monospaced())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
    }
}
