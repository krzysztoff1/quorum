import AppKit
import QuorumCore

struct AppShot {
    let brain: String?
    let select: String?
    let palette: String?
    let scope: String?
    let tier: Tier?
    let claims: Int
    let openCite: String?
    let fakeProgress: Bool
    let work: Bool
    let hideSidebar: Bool
    let followUp: Bool
    let fullSource: Bool
    let size: CGSize?
    let output: String?
    let delay: TimeInterval

    static let current = AppShot(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        brain = value("--brain")
        select = value("--select")
        palette = arguments.contains("--palette") ? (value("--palette").flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "") : nil
        scope = value("--scope")
        tier = value("--tier").flatMap(Tier.init(rawValue:))
        claims = value("--claims").flatMap(Int.init) ?? 0
        openCite = value("--open-cite")
        fakeProgress = arguments.contains("--fake-progress")
        work = arguments.contains("--work")
        hideSidebar = arguments.contains("--hide-sidebar")
        followUp = arguments.contains("--follow-up")
        fullSource = arguments.contains("--full-source")
        size = value("--size").flatMap { text in
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        }
        output = value("--shoot")
        delay = value("--shoot-after").flatMap(Double.init) ?? 4
    }

    var isActive: Bool { output != nil || select != nil || palette != nil || scope != nil || brain != nil }

    @MainActor
    func apply(to model: AppModel) {
        if let size, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppShell.windowID }) {
            window.setContentSize(size)
            window.center()
        }
        if hideSidebar { model.sidebarVisible = false }
        if fakeProgress {
            for thread in model.threads { if let run = thread.runningRun {
                model.progress[run.id] = RunProgress(stage: "research", stageIndex: 2, stageCount: 5, tasksDone: 2, tasksTotal: 3,
                                                     sourcesRead: 31, etaSeconds: 540)
            } }
        }
        if let select {
            let found = model.threads.first { $0.id == select || $0.title.localizedCaseInsensitiveContains(select) }
            if let found { model.select(question: found.id) }
        }
        if let scope { model.select(.new); Self.stageScoping(model, scope: scope, tier: tier ?? .deep) }
        if work { model.dispatch(.toggleWork) }
        if let cite = openCite {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.reading?.opened = cite; model.reading?.fullSource = fullSource }
        }
        if claims > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for _ in 0..<claims { model.dispatch(.nextClaim) }
            }
        }
        if followUp { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.dispatch(.followUp) } }
        if let palette { model.paletteOpen = true; model.paletteSeed = palette }
    }

    @MainActor
    private static func stageScoping(_ model: AppModel, scope: String, tier: Tier) {
        let composer = model.composer
        composer.flow.draft = "do research on personalization systems in food tech"
        guard let request = composer.flow.submit(), scope != "scoping" else { return }
        let brief = Brief(asked: request.question,
                          question: "How do DoorDash, Uber Eats and Instacart build personalization, how much does it earn them, and what law covers diet data?",
                          title: "Personalization in food tech", language: "en", tier: tier, suggestedTier: .deep,
                          tierReason: "3 topics", clarifications: [])
        let questions = scope == "clarifying" ? [
            ScopeQuestion(id: "q1", text: "What matters most?", multi: true, options: [
                ScopeOption(id: "a", label: "How it works technically"), ScopeOption(id: "b", label: "What it earns"),
                ScopeOption(id: "c", label: "Law and diet data"), ScopeOption(id: "d", label: "Deploying it in our app")]),
            ScopeQuestion(id: "q2", text: "Which companies to focus on?", multi: false, options: [
                ScopeOption(id: "a", label: "DoorDash, Uber Eats, Instacart"), ScopeOption(id: "b", label: "Wolt, Glovo, Pyszne.pl"),
                ScopeOption(id: "c", label: "Catering B2B")]),
        ] : []
        composer.flow.receive(ScopeReply(needsScoping: !questions.isEmpty, brief: brief, questions: questions, fallbackReason: nil), for: request.ticket)
        if scope == "clarifying" { composer.flow.pick(question: 0, option: 0); composer.flow.pick(question: 0, option: 1); composer.flow.pick(question: 1, option: 0) }
    }

    @MainActor
    func scheduleShot() {
        guard let output else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let written = Self.write(to: output)
            FileHandle.standardError.write(Data((written ? "wrote \(output)\n" : "could not write \(output)\n").utf8))
            NSApp.terminate(nil)
        }
    }

    @MainActor
    static func write(to output: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: output))) != nil
    }
}
