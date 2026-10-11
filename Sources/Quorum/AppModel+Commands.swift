import Foundation
import AppKit
import QuorumCore

extension AppModel {
    var keyScope: KeyScope {
        if paletteOpen { return .palette }
        switch selection {
        case .new: return composer.flow.step == .drafting ? .composer : .scoping(composer.flow.step)
        case .question: return .question(railOpen: reading?.navigator.railOpen ?? false)
        }
    }

    func dispatch(_ command: AppCommand) {
        switch command {
        case .palette: paletteOpen.toggle()
        case .newQuestion:
            paletteOpen = false
            select(.new)
            composer.focusDraft()
        case .jumpToQuestion(let position): selectNth(position)
        case .previousQuestion: selectNext(by: -1)
        case .nextQuestion: selectNext(by: 1)
        case .toggleSidebar: sidebarVisible.toggle()
        case .nextClaim: reading?.navigator.next()
        case .previousClaim: reading?.navigator.previous()
        case .openSource: reading?.navigator.openFirstSource()
        case .nextSource: reading?.navigator.cycleSource(by: 1)
        case .previousSource: reading?.navigator.cycleSource(by: -1)
        case .closeRail: reading?.navigator.close()
        case .openOriginal: openOriginalOfOpenSource()
        case .researchConflict: seedConflictFollowUp()
        case .toggleEarlier: showsEarlier.toggle()
        case .toggleWork: if selectedThread?.isRunning == true { showsWork.toggle() }
        case .followUp: followUpFocus += 1
        case .copyMarkdown: if let thread = selectedThread { copyMarkdown(thread) }
        case .stop: if let running = selectedThread?.runningRun { stop(runID: running.id) }
        case .toggleTier: composer.toggleTier()
        case .ask: composer.ask()
        case .pickOption(let question, let option): composer.pick(question: question, option: option)
        case .continueScoping: composer.continueClarifying()
        case .backToWords: composer.backToWords()
        case .startRun: composer.start()
        case .editResolved: composer.beginEditingResolved()
        }
    }

    func perform(_ command: PaletteCommand) {
        switch command {
        case .newQuestion: dispatch(.newQuestion)
        case .chooseBrain: chooseBrainFolder()
        case .revealInFinder: if let thread = selectedThread { reveal(thread) }
        case .openInClaudeCode: if let thread = selectedThread { openInClaudeCode(thread) }
        case .copyMarkdown: dispatch(.copyMarkdown)
        case .goDeeper: if let thread = selectedThread { goDeeper(thread) }
        case .showWork: dispatch(.toggleWork)
        case .stopAll: stopAll()
        case .settings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .toggleSidebar: dispatch(.toggleSidebar)
        }
    }

    func perform(_ action: PaletteAction) {
        paletteOpen = false
        switch action {
        case .openQuestion(let id): select(question: id)
        case .openSource(let question, let cite):
            select(question: question)
            pendingCite = cite
        case .askNew(let text):
            select(.new)
            composer.seed(text)
            composer.ask()
        case .followUp(let question, let text):
            guard let thread = thread(question) else { return }
            select(question: question)
            _ = followUp(thread, text: text)
        case .command(let command): perform(command)
        }
    }

    private func seedConflictFollowUp() {
        guard let thread = selectedThread, let run = viewedAnswer(of: thread),
              let page = AnswerPage(run: run), let conflict = page.openItems.conflicts.first else { return }
        composerSeed = self.page(for: thread).conflictFollowUp(statement: conflict.statement)
        followUpFocus += 1
    }

    private func openOriginalOfOpenSource() {
        guard let thread = selectedThread, let run = viewedAnswer(of: thread), let cite = reading?.navigator.opened,
              let citation = run.record.citations.first(where: { $0.id == cite }),
              let source = run.record.sources.first(where: { $0.id == citation.sourceID }),
              let url = URL(string: source.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
