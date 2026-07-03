import SwiftUI
import NightYokeCore

// MARK: - Ask your brain (story 40)
//
// A query box that answers from your own notes first — the existing keyword matcher pre-selects the notes
// most related to your question (see BrainQuery in Core) — and searches the web only for what the notes
// don't cover. Turns a write-only pile of research into a knowledge base you actually consult. Reuses
// ChatRunner (the same subprocess as the chat) + MarkdownView; single-shot per question.

@MainActor
@Observable
final class AskModel {
    var question = ""
    var askedQuestion = ""              // the question the current answer is for (shown above the answer)
    var answer = ""
    var isStreaming = false
    var matched: [BrainQuery.Note] = [] // notes the brain consulted, shown as tappable chips

    let projectURL: URL
    private let store = DiskFindingsStore()
    private var task: Task<Void, Never>?

    init(projectURL: URL) { self.projectURL = projectURL }

    /// Answer the current question: matcher → notes-first prompt → stream the reply.
    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        task?.cancel()
        askedQuestion = q
        answer = ""
        isStreaming = true

        let bq = BrainQuery.build(question: q, brain: projectURL, store: store)
        matched = bq.notes

        // useProjectContext: true → the agent also gets read-only file tools, so it can open the full note
        // on disk when an excerpt was truncated; WebSearch/WebFetch cover "the gap".
        // ponytail: no spend cap here, same as the chat — add --max-budget-usd via ChatRunner if asks get pricey.
        let sid = UUID().uuidString, project = projectURL, mdl = ModelChoice.stored("chatModel")
        task = Task { [weak self] in
            await ChatRunner.stream(message: bq.prompt, sessionID: sid, resume: false,
                                    projectURL: project, model: mdl, useProjectContext: true) { full in
                DispatchQueue.main.async { self?.answer = full }
            }
            await MainActor.run {
                guard let self else { return }
                if self.answer.isEmpty { self.answer = "_(no response)_" }
                self.isStreaming = false
            }
        }
    }

    func stop() { task?.cancel(); isStreaming = false }
}

struct AskView: View {
    @Bindable var model: AppModel
    @State private var ask: AskModel?

    var body: some View {
        Group {
            if let ask {
                AskContent(ask: ask)
            } else {
                ContentUnavailableView("Pick a project folder", systemImage: "folder.badge.plus",
                    description: Text("Your brain’s notes live in a project folder. Choose one to ask."))
            }
        }
        .navigationTitle("Ask your brain")
        .task { if ask == nil, let p = model.projectURL { ask = AskModel(projectURL: p) } }
    }
}

private struct AskContent: View {
    @Bindable var ask: AskModel
    @State private var reading: BrainQuery.Note?   // tapped note → its writeup in a sheet

    private static let examples = [
        "What do I know about our onboarding?",
        "What did I find on making the app faster?",
        "What have I learned about visualizing our data?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            queryBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if ask.askedQuestion.isEmpty { intro } else { results }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ask.answer) { _, _ in withAnimation(.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) } }
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

    private var queryBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").font(.title3).foregroundStyle(Color.accentColor)
            TextField("Ask what your brain knows…", text: $ask.question, axis: .vertical)
                .textFieldStyle(.plain).font(.title3).lineLimit(1...5)
                .onSubmit { ask.ask() }
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            if ask.isStreaming {
                Button { ask.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.red)
            } else {
                Button { ask.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(ask.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Ask your brain", systemImage: "brain").font(.title2.bold())
                Text("Get an answer from your own research notes first. NightYoke pulls the notes most related to your question and answers from them — searching the web only to fill what they don’t cover.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Try:").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.examples, id: \.self) { ex in
                    Button { ask.question = ex; ask.ask() } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkle").font(.caption2)
                            Text(ex).multilineTextAlignment(.leading)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        Text(ask.askedQuestion).font(.title3.weight(.semibold)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        matchedStrip
        Divider()
        answerCard
    }

    @ViewBuilder private var matchedStrip: some View {
        if ask.matched.isEmpty {
            Label("No matching notes in your brain — answering from the web.", systemImage: "globe")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Consulted \(ask.matched.count) note\(ask.matched.count == 1 ? "" : "s") from your brain",
                      systemImage: "brain").font(.callout.weight(.medium))
                ForEach(ask.matched) { note in
                    Button { reading = note } label: {
                        Label(note.title, systemImage: "doc.text").lineLimit(1)
                    }
                    .buttonStyle(.link).font(.callout)
                }
            }
        }
    }

    @ViewBuilder private var answerCard: some View {
        if ask.answer.isEmpty && ask.isStreaming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Consulting your brain…").foregroundStyle(.secondary)
            }
        } else if !ask.answer.isEmpty {
            MarkdownView(markdown: ask.answer).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
