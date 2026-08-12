import HarnessMonitorKit

@MainActor
struct TaskBoardTriageRulesEditorActions {
  let store: HarnessMonitorStore
  let state: TaskBoardTriageRulesEditorState

  var isWriteAuthorized: Bool {
    guard let profile = store.remoteDaemonProfile else { return true }
    return profile.status == .active
      && profile.role != .viewer
      && profile.scopes.contains("write")
  }

  func load() {
    guard !state.isBusy else { return }
    state.isBusy = true
    let historyLimit = TaskBoardTriageRulesEditorLoadProjection.historyLimit
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading triage rules") {
        async let draftResponse = store.taskBoardTriageRulesDraft()
        async let revisionsResponse = store.taskBoardTriageRulesRevisions(limit: historyLimit)
        async let auditResponse = store.taskBoardTriageRulesAudit(limit: historyLimit)
        let (draft, revisions, audit) = await (draftResponse, revisionsResponse, auditResponse)
        let projection = TaskBoardTriageRulesEditorLoadProjection(
          draft: draft?.draft,
          revisions: revisions?.revisions ?? [],
          audit: audit?.audit ?? []
        )
        await MainActor.run {
          state.applyLoad(projection)
          state.isBusy = false
        }
      }
    )
  }

  func saveDraft() {
    guard isWriteAuthorized else {
      state.statusMessage = "Remote viewer access is read-only"
      return
    }
    guard !state.isBusy else { return }
    guard let candidate = state.decodedCandidate() else {
      state.statusMessage = "Rules text is not valid JSON for the current schema"
      return
    }
    state.isBusy = true
    let expectedRevision = state.draftRevision
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Saving triage rules draft") {
        let result = await store.saveTaskBoardTriageRulesDraft(
          rules: candidate,
          expectedRevision: expectedRevision
        )
        await MainActor.run {
          state.validation = result?.validation
          if let result, result.persisted {
            state.draftRevision = result.revision
            state.statusMessage = "Draft saved"
          } else if result != nil {
            state.statusMessage = "Draft rejected: see validation issues below"
          }
          state.isBusy = false
        }
      }
    )
  }

  func preview() {
    guard !state.isBusy, let candidate = state.decodedCandidate() else {
      state.statusMessage = "Rules text is not valid JSON for the current schema"
      return
    }
    state.isBusy = true
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Previewing triage rules") {
        let result = await store.previewTaskBoardTriageRules(
          request: TaskBoardPreviewTriageRulesRequest(rules: candidate)
        )
        await MainActor.run {
          state.validation = result?.validation
          state.previewDiff = result?.diff
          state.isBusy = false
        }
      }
    )
  }

  func activate() {
    guard isWriteAuthorized else {
      state.statusMessage = "Remote viewer access is read-only"
      return
    }
    guard !state.isBusy else { return }
    guard let candidate = state.decodedCandidate() else {
      state.statusMessage = "Rules text is not valid JSON for the current schema"
      return
    }
    runActivation(rules: candidate, statusOnSuccess: "Triage rules activated")
  }

  func deactivate() {
    guard isWriteAuthorized else {
      state.statusMessage = "Remote viewer access is read-only"
      return
    }
    guard !state.isBusy else { return }
    runActivation(
      rules: nil, statusOnSuccess: "Triage rules deactivated (BuiltInV1 default restored)")
  }

  private func runActivation(rules: TriageRuleSetV1?, statusOnSuccess: String) {
    state.isBusy = true
    let expectedActiveRevision = state.activeRevision
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: rules == nil ? "Deactivating triage rules" : "Activating triage rules") {
        let result = await store.activateTaskBoardTriageRules(
          rules: rules,
          expectedActiveRevision: expectedActiveRevision
        )
        await MainActor.run {
          state.validation = result?.validation
          if let result, result.activated {
            state.activeRevision = result.revision
            state.statusMessage = statusOnSuccess
          } else if result != nil {
            state.statusMessage = "Activation rejected: see validation issues below"
          }
          state.isBusy = false
        }
        await load()
      }
    )
  }
}
