import Foundation
import SwiftUI
import QuorumCore

@MainActor
@Observable
final class ComposerModel {
    var flow = ScopingFlow()
    var focusRequest = 0
    var starting = false
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var scopeTask: Task<Void, Never>?

    var canAsk: Bool {
        (app?.canRun ?? false) && !flow.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func focusDraft() { focusRequest += 1 }

    func reset() {
        scopeTask?.cancel()
        flow.reset()
        starting = false
    }

    func ask() {
        guard canAsk, let request = flow.submit() else { return }
        requestScope(request)
    }

    func toggleTier() { flow.toggleTier() }

    func pick(question: Int, option: Int) { flow.pick(question: question, option: option) }

    func continueClarifying() {
        if let request = flow.continueClarifying() { requestScope(request) }
    }

    func backToWords() {
        scopeTask?.cancel()
        flow.edit()
        focusDraft()
    }

    func beginEditingResolved() { flow.beginEditingResolved() }

    func commitResolvedEdit() { flow.commitResolvedEdit() }

    func cancelResolvedEdit() { flow.cancelResolvedEdit() }

    func start() {
        guard let start = flow.confirm() else { return }
        launch(start)
    }

    func startAsWritten() {
        guard let start = flow.runAsWritten() else { return }
        launch(start)
    }

    func seed(_ text: String, tier: Tier? = nil) {
        reset()
        flow.draft = text
        if let tier, flow.tier != tier { flow.toggleTier() }
        focusDraft()
    }

    private func launch(_ start: RunStart) {
        guard let app, app.startRun(start) else { return }
        starting = true
    }

    private func requestScope(_ request: ScopeRequest) {
        scopeTask?.cancel()
        scopeTask = Task { [weak self] in
            guard let self, let app = self.app else { return }
            let result = await app.scope(request)
            switch result {
            case .success(let reply): self.flow.receive(reply, for: request.ticket)
            case .failure(let failure): self.flow.fail(failure, for: request.ticket)
            }
        }
    }
}
