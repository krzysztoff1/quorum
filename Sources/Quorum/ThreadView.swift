import SwiftUI
import QuorumCore

struct ThreadView: View {
    @Bindable var model: AppModel
    let thread: QuestionThread

    private var page: ThreadPage { model.page(for: thread) }
    private var viewed: StoredRun? { model.viewedAnswer(of: thread) }
    private var running: StoredRun? { thread.runningRun }
    private var live: LiveRun? { running.flatMap { model.liveRuns[$0.id] } }
    private var showsLiveGraph: Bool { model.showsWork && running != nil }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(crumb: crumb) { topActions }
            content
            KeyBar(hints: hints, trailing: trailing)
        }
        .background(Ink.ink1)
        .onChange(of: running?.id) { _, id in if id == nil { model.showsWork = false } }
    }

    private var crumb: String { thread.title.isEmpty ? "Untitled" : thread.title }

    @ViewBuilder private var content: some View {
        if showsLiveGraph, let live {
            ResearchGraphView(graph: live.graph, showsUnvalidatedBanner: false, live: { live.liveByAngle[$0] }, scrolls: true)
        } else if let viewed {
            AnswerHost(model: model, thread: thread, run: viewed, banner: running.map { AnyView(ProgressCard(model: model, thread: thread, run: $0, compact: true)) })
                .id(viewed.id)
        } else if let running {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ThreadHeader(thread: thread, page: page)
                    ProgressCard(model: model, thread: thread, run: running, compact: false)
                }
                .frame(maxWidth: 840, alignment: .leading).padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
        } else {
            Unfinished(model: model, thread: thread)
        }
    }

    @ViewBuilder private var topActions: some View {
        HStack(spacing: 4) {
            if model.viewingRunID(thread) != nil {
                TopBarButton(icon: nil, title: "Back to the answer") { model.viewing[thread.id] = nil }
            }
            if viewed != nil && running == nil {
                TopBarButton(icon: nil, title: "Copy", key: "⌘⇧C") { model.dispatch(.copyMarkdown) }
            }
            TopBarButton(icon: .search, title: "Search", key: "⌘K") { model.dispatch(.palette) }
            if running != nil {
                TopBarButton(icon: .work, title: showsLiveGraph ? "Hide the work" : "Show the work", key: "G", active: showsLiveGraph) { model.dispatch(.toggleWork) }
            }
            Menu {
                Button("Open in Claude Code") { model.openInClaudeCode(thread) }
                Button("Show in Finder") { model.reveal(thread) }
                if viewed != nil { Button("Copy as Markdown") { model.copyMarkdown(thread) } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text2)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    private var hints: [KeyHint] {
        if running != nil {
            return [KeyHint(caps: ["G"], label: showsLiveGraph ? "hide the work" : "show the work"), KeyHint(caps: ["⌘."], label: "stop"), KeyHint(caps: ["N"], label: "ask something else meanwhile")]
        }
        if model.railOpen {
            return [KeyHint(caps: ["["], label: "prev source"), KeyHint(caps: ["]"], label: "next source"), KeyHint(caps: ["⌘⏎"], label: "open original"), KeyHint(caps: ["esc"], label: "close")]
        }
        var hints = [KeyHint(caps: ["J", "K"], label: "claims"), KeyHint(caps: ["⏎"], label: "open source")]
        if page.canFollowUp { hints.append(KeyHint(caps: ["⌘L"], label: "follow up")) }
        hints.append(KeyHint(caps: ["⌘⇧C"], label: "copy as markdown"))
        return hints
    }

    private var trailing: String {
        if running != nil { return "Runs on your Claude subscription" }
        guard let run = viewed, let url = AnswerExport.url(forQuestion: thread.id, in: model.brainURL) else { _ = viewed; return "" }
        return "Saved to \(model.brainName) · \(url.lastPathComponent)"
    }
}

struct ThreadHeader: View {
    let thread: QuestionThread
    let page: ThreadPage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Avatar(letter: "KD")
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.askedText).font(Typeface.ui(17)).foregroundStyle(Ink.text1).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let tier = thread.runningRun?.tier ?? thread.current?.tier { Text(tier.displayName) }
                        if let scope = page.scopeLine { Text("·"); Text(scope) }
                    }
                    .font(Typeface.ui(12.5)).foregroundStyle(Ink.text3)
                }
            }
            if !thread.resolvedText.isEmpty && thread.resolvedText != thread.askedText {
                Text(thread.resolvedText).font(Typeface.read(19)).foregroundStyle(Ink.text2).lineSpacing(4)
                    .padding(.leading, 42).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 26)
    }
}

struct ProgressCard: View {
    @Bindable var model: AppModel
    let thread: QuestionThread
    let run: StoredRun
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let strip = StageStrip(progress: model.progress[run.id], tier: run.tier, choices: run.record.brief.clarifications?.count ?? 0,
                                   startedAt: run.createdAt, now: timeline.date, calendar: .current)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TierGlyph(tier: run.tier ?? .quick, size: 16, color: Ink.iris, pulsing: true)
                    Text(strip.headline).font(Typeface.ui(16, .semibold)).foregroundStyle(Ink.text1)
                    if let tier = run.tier { Text(tier.displayName).font(Typeface.ui(12.5)).foregroundStyle(Ink.iris) }
                    Spacer()
                    Text(strip.clock).font(Typeface.ui(12.5)).foregroundStyle(Ink.text3).monospacedDigit()
                    Button { model.stop(runID: run.id) } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Ink.text2).frame(width: 8, height: 8)
                            Text("Stop").font(Typeface.ui(12.5, .medium)).foregroundStyle(Ink.text2)
                        }
                        .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop this run")
                }
                .padding(.bottom, 18)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(strip.stages) { stage in StageColumn(stage: stage) }
                }
                if !compact {
                    Ink.line.frame(height: 1).padding(.top, 20)
                    HStack {
                        Text("You can close Quorum. It keeps going, and the answer lands in your inbox.").font(Typeface.ui(12.5)).foregroundStyle(Ink.text3)
                        Spacer()
                        Toggle("Notify me", isOn: $model.notifyOnFinish).toggleStyle(.switch).controlSize(.small).tint(Ink.iris)
                            .font(Typeface.ui(12.5)).foregroundStyle(Ink.text2)
                    }
                    .padding(.top, 14)
                }
            }
            .padding(compact ? 16 : 22)
            .background(Ink.ink2.opacity(compact ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(strip.headline). \(strip.clock)")
        }
    }
}

private struct StageColumn: View {
    let stage: StageStrip.Stage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.ink4)
                    Capsule().fill(stage.state == .done ? Ink.text3 : Ink.iris).frame(width: proxy.size.width * stage.fraction)
                }
            }
            .frame(height: 2)
            Text(stage.name).font(Typeface.ui(13, stage.state == .current ? .semibold : .regular))
                .foregroundStyle(stage.state == .pending ? Ink.text3 : Ink.text1)
            Text(stage.detail).font(Typeface.ui(12)).foregroundStyle(Ink.text3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.reveal, value: stage.fraction)
    }
}

private struct Unfinished: View {
    @Bindable var model: AppModel
    let thread: QuestionThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThreadHeader(thread: thread, page: model.page(for: thread))
                if let run = thread.latest { Notice(text: RunVerdict.sentence(for: run), tone: run.record.status == .failed || run.record.status == .crashed ? Ink.rose : Ink.amber) }
                HStack(spacing: 8) {
                    PrimaryButton(title: "Ask again") {
                        model.select(.new)
                        model.composer.seed(thread.askedText)
                    }
                    GhostButton(title: "Show in Finder") { model.reveal(thread) }
                }
            }
            .frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 40).padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AnswerHost: View {
    @Bindable var model: AppModel
    let thread: QuestionThread
    let run: StoredRun
    let banner: AnyView?
    @StateObject private var focus: AnswerFocus
    private let context: AnswerContext?

    init(model: AppModel, thread: QuestionThread, run: StoredRun, banner: AnyView?) {
        self.model = model
        self.thread = thread
        self.run = run
        self.banner = banner
        let context = AnswerContext(run: run)
        self.context = context
        _focus = StateObject(wrappedValue: AnswerFocus(entries: context?.page.navigatorEntries ?? []))
    }

    private var meta: String {
        let base = AnswerContext.meta(run)
        guard let scope = model.page(for: thread).scopeLine else { return base }
        return base + "  ·  " + scope
    }

    var body: some View {
        VStack(spacing: 0) {
            if let banner { banner.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 4) }
            if RunVerdict.needsNotice(run) {
                Notice(text: RunVerdict.sentence(for: run), tone: Ink.amber).frame(maxWidth: 688).padding(.horizontal, 24).padding(.top, 14).frame(maxWidth: .infinity)
            }
            if let context {
                AnswerScreen(context: context, focus: focus, meta: meta, tier: run.tier,
                             evidenceDirectory: run.evidenceDirectory, scrolls: true,
                             footer: AnyView(ThreadFooter(model: model, thread: thread)))
            } else {
                Notice(text: RunVerdict.sentence(for: run), tone: Ink.amber).padding(40)
                Spacer()
            }
        }
        .onAppear {
            model.reading = focus
            if let cite = model.pendingCite { focus.opened = cite; model.pendingCite = nil }
        }
        .onDisappear {
            if model.reading === focus { model.reading = nil }
            model.railOpen = false
        }
        .onChange(of: focus.navigator.railOpen) { _, open in model.railOpen = open }
        .onChange(of: model.pendingCite) { _, cite in
            guard let cite else { return }
            focus.opened = cite
            model.pendingCite = nil
        }
    }
}

private struct ThreadFooter: View {
    @Bindable var model: AppModel
    let thread: QuestionThread
    @State private var text = ""
    @FocusState private var focused: Bool

    private var page: ThreadPage { model.page(for: thread) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.canGoDeeper {
                HStack(spacing: 10) {
                    TierGlyph(tier: .deep, size: 14, color: Ink.iris)
                    Text("This was a Quick answer.").font(Typeface.ui(13.5)).foregroundStyle(Ink.text2)
                    Spacer()
                    GhostButton(title: "Go deeper") { model.goDeeper(thread) }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
                .padding(.top, 36)
            }
            if !page.followUps.isEmpty { followUps.padding(.top, 36) }
            if !page.earlier.isEmpty { earlier.padding(.top, 28) }
            if page.canFollowUp { composer.padding(.top, 36) }
        }
        .onChange(of: model.followUpFocus) { _, _ in
            if let seed = model.composerSeed { text = seed; model.composerSeed = nil }
            focused = true
        }
    }

    private var followUps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Follow-ups").font(Typeface.ui(13, .semibold)).foregroundStyle(Ink.text1).padding(.bottom, 10)
            ForEach(page.followUps) { item in
                FollowUpRow(item: item, lead: lead(of: item.runID)) { model.viewing[thread.id] = item.runID }
            }
        }
        .overlay(alignment: .top) { Ink.line.frame(height: 1).offset(y: -18) }
    }

    private func lead(of runID: String) -> String? {
        guard let run = thread.runs.first(where: { $0.id == runID }), let page = AnswerPage(run: run) else { return nil }
        return CitationMarkers.stripping(page.lead)
    }

    private var earlier: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(Motion.reveal) { model.showsEarlier.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(model.showsEarlier ? 90 : 0))
                    Text("\(page.earlier.count) earlier answer\(page.earlier.count == 1 ? "" : "s")")
                    KeyCap(label: "E")
                }
                .font(Typeface.ui(12.5)).foregroundStyle(Ink.text3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.showsEarlier {
                ForEach(page.earlier) { item in
                    Button { model.viewing[thread.id] = item.runID } label: {
                        Text(item.label).font(Typeface.ui(13)).foregroundStyle(Ink.text2).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask a follow-up — it researches with this answer as context", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Typeface.ui(14.5)).foregroundStyle(Ink.text1)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { submit() }
                .accessibilityLabel("Follow-up question")
            HStack(spacing: 8) {
                Text("Quick").font(Typeface.ui(12, .medium)).foregroundStyle(Ink.text2)
                    .padding(.horizontal, 8).frame(height: 22).background(Ink.ink4, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                KeyCap(label: "⌘L")
                KeyCap(label: "⏎")
            }
        }
        .padding(14)
        .background(Ink.ink2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Ink.irisLine : Ink.line))
        .animation(Motion.hover, value: focused)
    }

    private func submit() {
        guard model.followUp(thread, text: text) else { return }
        text = ""
        focused = false
    }
}

private struct FollowUpRow: View {
    let item: ThreadPage.FollowUp
    let lead: String?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    switch item.state {
                    case .running: TierGlyph(tier: .quick, size: 12, color: Ink.iris, pulsing: true)
                    case .failed: IconView(icon: .gap, size: 12, color: Ink.amber)
                    case .answered: IconView(icon: .check, size: 12, color: Ink.text3)
                    }
                    Text(item.question).font(Typeface.ui(13.5, .medium)).foregroundStyle(Ink.text1).lineLimit(2)
                }
                if let lead { Text(lead).font(Typeface.ui(13)).foregroundStyle(Ink.text2).lineLimit(3).padding(.leading, 20) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(hovering ? Ink.ink2 : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.state != .answered)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}
