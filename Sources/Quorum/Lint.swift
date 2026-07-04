import SwiftUI
import QuorumCore

// MARK: - Brain health check (whole-wiki lint)
//
// The per-run conflict/gap logic of an iterative fan-out, lifted to run across the WHOLE brain. One
// streamed reasoning pass (not a fan-out — the data is already on disk) reports contradictions, gaps, and
// worth-researching questions; missing [[wikilink]] connections are found deterministically in Core. Every
// finding is actionable: a gap or question becomes a research run with one click, and the report files back
// into the brain. Reuses BrainLint (Core) + ChatRunner + MarkdownView, mirroring Ask.

@MainActor
@Observable
final class LintModel {
    var answer = ""
    var report: BrainLintReport?
    var candidates: [BrainLint.ConnectionCandidate] = []
    var notes: [BrainLint.NoteSummary] = []
    var isStreaming = false
    var hasRun = false
    var savedPath: String?

    let projectURL: URL
    private let store = DiskFindingsStore()
    private var task: Task<Void, Never>?

    init(projectURL: URL) { self.projectURL = projectURL }

    /// Audit the whole brain: build the prompt + deterministic connections, then stream the reasoning pass
    /// (or, in a dev dry run, resolve a canned report with no subprocess) and parse the findings on finish.
    func run(dryRun: Bool) {
        guard !isStreaming else { return }
        task?.cancel()
        hasRun = true
        answer = ""
        report = nil
        savedPath = nil
        isStreaming = true

        let lint = BrainLint.build(brain: projectURL, store: store)
        candidates = lint.unlinkedCandidates
        notes = lint.notes

        if dryRun {
            answer = DryRunExecutor.cannedLint(for: lint.prompt) ?? "_(dry run — no lint response)_"
            report = BrainLintReport.parse(answer)
            isStreaming = false
            return
        }

        // useProjectContext: true → the agent also gets read-only file tools, so it can open the full note
        // on disk when a summary was too thin to judge a contradiction.
        let sid = UUID().uuidString, project = projectURL, mdl = ModelChoice.stored("chatModel")
        task = Task { [weak self] in
            await ChatRunner.stream(message: lint.prompt, sessionID: sid, resume: false,
                                    projectURL: project, model: mdl, useProjectContext: true) { full in
                DispatchQueue.main.async { self?.answer = full }
            }
            await MainActor.run {
                guard let self else { return }
                if self.answer.isEmpty { self.answer = "_(no response)_" }
                self.report = BrainLintReport.parse(self.answer)
                self.isStreaming = false
            }
        }
    }

    func stop() { task?.cancel(); isStreaming = false }

    /// Path → title for a connection candidate's note (candidates carry slugs; the summaries carry paths).
    func note(forSlug slug: String) -> BrainLint.NoteSummary? { notes.first { $0.slug == slug } }

    /// The full report to file back into the brain: the deterministic connections + the model's write-up.
    var reportMarkdown: String {
        var md = "# Brain health check\n\n"
        if !candidates.isEmpty {
            md += "## Missing connections\n\n"
            for c in candidates { md += "- [[\(c.fromSlug)]] ↔ [[\(c.toSlug)]] — \(c.fromTitle) / \(c.toTitle)\n" }
            md += "\n"
        }
        md += answer
        return md
    }

    func save() {
        guard report != nil || !answer.isEmpty else { return }
        savedPath = try? store.writeLintReport(markdown: reportMarkdown, brain: projectURL, at: Date()).path
    }
}

struct LintView: View {
    @Bindable var model: AppModel
    @State private var lint: LintModel?

    var body: some View {
        Group {
            if let lint {
                LintContent(model: model, lint: lint)
            } else {
                ContentUnavailableView("Pick a project folder", systemImage: "folder.badge.plus",
                    description: Text("Your brain’s notes live in a project folder. Choose one to run a health check."))
            }
        }
        .navigationTitle("Health check")
        .task { if lint == nil, let p = model.projectURL { lint = LintModel(projectURL: p) } }
    }
}

private struct OpenNote: Identifiable { let title: String; let path: String; var id: String { path } }

private struct LintContent: View {
    @Bindable var model: AppModel
    @Bindable var lint: LintModel
    @State private var reading: OpenNote?

    var body: some View {
        VStack(spacing: 0) {
            runBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !lint.hasRun { intro } else { results }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                    .readableColumn()
                }
                .onChange(of: lint.answer) { _, _ in withAnimation(.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .sheet(item: $reading) { note in
            NavigationStack {
                ScrollView { WriteupContent(path: note.path).padding(24) }
                    .navigationTitle(note.title)
                    .toolbar { Button("Done") { reading = nil } }
            }
            .frame(minWidth: 520, minHeight: 460)
        }
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope").font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Health check").font(.headline)
                Text("Audit your whole brain for contradictions, gaps, and missing links.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if lint.isStreaming {
                Button { lint.stop() } label: { Label("Stop", systemImage: "stop.circle.fill") }
                    .tint(.red)
            } else {
                Button { lint.run(dryRun: model.dryRun) } label: {
                    Label(lint.hasRun ? "Re-run" : "Run health check", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Audit your whole brain", systemImage: "brain").font(.title2.bold())
            Text("Quorum reads every note and reports what’s wrong across the whole set: claims that contradict each other, questions your notes raise but never answer, and notes that should link but don’t. Turn any gap or question into a research run with one click.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { lint.run(dryRun: model.dryRun) } label: {
                Label("Run health check", systemImage: "sparkles").font(.headline)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder private var results: some View {
        connectionsSection
        if let report = lint.report {
            inconsistenciesSection(report)
            listSection("Gaps", systemImage: "questionmark.diamond.fill", tint: .orange,
                        empty: "No open questions the notes raise but don’t answer.", items: report.gaps)
            listSection("Suggested questions", systemImage: "lightbulb.fill", tint: .yellow,
                        empty: "No new research suggested.", items: report.questions)
            actionsRow
            if !lint.answer.isEmpty {
                DisclosureGroup("Full write-up") {
                    MarkdownView(markdown: lint.answer).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        } else if lint.isStreaming {
            if lint.answer.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Auditing your brain…").foregroundStyle(.secondary) }
            } else {
                MarkdownView(markdown: lint.answer).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: sections

    @ViewBuilder private var connectionsSection: some View {
        sectionHeader("Missing connections", systemImage: "link", tint: .blue)
        if lint.candidates.isEmpty {
            emptyRow("Every related pair of notes already links.")
        } else {
            ForEach(lint.candidates) { c in
                HStack(spacing: 6) {
                    linkButton(title: c.fromTitle, slug: c.fromSlug)
                    Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(.secondary)
                    linkButton(title: c.toTitle, slug: c.toSlug)
                }
            }
        }
    }

    @ViewBuilder private func inconsistenciesSection(_ report: BrainLintReport) -> some View {
        sectionHeader("Inconsistencies", systemImage: "exclamationmark.triangle.fill", tint: .red)
        if report.inconsistencies.isEmpty {
            emptyRow("No contradictions found across your notes.")
        } else {
            ForEach(Array(report.inconsistencies.enumerated()), id: \.offset) { _, inc in
                VStack(alignment: .leading, spacing: 3) {
                    Text(inc.claim).font(.callout.weight(.semibold))
                    if !inc.detail.isEmpty { Text(inc.detail).font(.callout).foregroundStyle(.secondary) }
                    if !inc.notes.isEmpty {
                        Text(inc.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// A gap/question list section — each item is a one-click "Research this" into the existing deep-dive.
    @ViewBuilder private func listSection(_ title: String, systemImage: String, tint: Color,
                                          empty: String, items: [String]) -> some View {
        sectionHeader(title, systemImage: systemImage, tint: tint)
        if items.isEmpty {
            emptyRow(empty)
        } else {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { research(item) } label: { Label("Research this", systemImage: "sparkles") }
                        .buttonStyle(.borderless).font(.callout).fixedSize()
                }
                .font(.callout)
            }
        }
    }

    private var actionsRow: some View {
        HStack {
            Button { lint.save() } label: { Label("Save to brain", systemImage: "square.and.arrow.down") }
                .disabled(lint.savedPath != nil)
            if lint.savedPath != nil {
                Label("Saved", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
        }
        .padding(.top, 4)
    }

    // MARK: bits

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage).font(.title3.weight(.semibold)).foregroundStyle(tint)
            .padding(.top, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func linkButton(title: String, slug: String) -> some View {
        Button {
            if let note = lint.note(forSlug: slug) { reading = OpenNote(title: note.title, path: note.path) }
        } label: {
            Label(title, systemImage: "doc.text").lineLimit(1)
        }
        .buttonStyle(.link).font(.callout)
    }

    private func research(_ question: String) {
        model.planDeepDive(question, count: 5)
        model.focusCompose = true
    }
}
