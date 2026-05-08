import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  @MainActor
  func submit() async {
    if let validationResult = SessionWindowCreateFormValidation.result(
      for: draft,
      capabilityOptions: activeAgentCapabilityOptions
    ) {
      self.validationResult = validationResult
      focusValidationField(validationResult.field)
      return
    }
    let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    validationResult = nil
    switch draft.kind {
    case .agent:
      await createAgent(named: name)
    case .task:
      await createTask(named: name)
    case .decision:
      await createDecision(summary: name)
    }
  }

  @MainActor
  func createAgent(named name: String) async {
    switch SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentCapabilityOptions
    ) {
    case .tui(let runtime):
      guard
        let created = await store.startAgentTuiSnapshot(
          runtime: runtime,
          name: name,
          prompt: draft.prompt,
          rows: 32,
          cols: 120,
          sessionID: draft.sessionID
        )
      else {
        return
      }
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    case .acp(let descriptorID):
      let capabilities = capabilities(for: .acp(descriptorID))
      guard
        let created = await store.startAcpAgent(
          agentID: descriptorID,
          capabilities: capabilities,
          name: name,
          prompt: draft.prompt,
          sessionID: draft.sessionID
        )
      else {
        return
      }
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    }
  }

  @MainActor
  func loadAgentCapabilitiesIfNeeded() async {
    guard draft.kind == .agent else { return }
    guard agentCapabilityOptions.isEmpty else { return }
    isLoadingAgentCapabilities = true
    let options = await SessionWindowCreateFormCatalogs.loadAgentOptions(store: store)
    agentCapabilityOptions = options
    isLoadingAgentCapabilities = false
    let normalized = SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: options
    )
    if normalized.storageKey != draft.launchSelection.storageKey {
      updateDraft(runtime: normalized.storageKey)
    }
  }

  func capabilities(for selection: AgentLaunchSelection) -> [String] {
    guard
      let option = activeAgentCapabilityOptions.first(where: { option in
        option.transportChoices.contains { $0.id == selection }
      })
    else {
      return []
    }
    return option.transportChoice(for: selection).capabilities
  }

  @MainActor
  func createTask(named name: String) async {
    let context = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await store.createTask(
      title: name,
      context: context.isEmpty ? nil : context,
      severity: draft.taskSeverity,
      sessionID: draft.sessionID
    )
    guard success else { return }
    state.updateCreateDraft(SessionCreateDraft(kind: .task, sessionID: draft.sessionID))
    state.selectRoute(.tasks)
  }

  @MainActor
  func createDecision(summary: String) async {
    guard let decisionStore = store.supervisorDecisionStore else {
      validationResult = .init(message: "Decision store is unavailable.", field: .form)
      return
    }
    let id = "manual-\(UUID().uuidString)"
    let decision = DecisionDraft(
      id: id,
      severity: .needsUser,
      ruleID: "manual-session-window",
      sessionID: draft.sessionID,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    do {
      try await decisionStore.insert(decision)
      state.updateCreateDraft(SessionCreateDraft(kind: .decision, sessionID: draft.sessionID))
      state.selectDecision(id)
    } catch {
      validationResult = .init(message: error.localizedDescription, field: .form)
    }
  }

  func validationMessage(
    for field: SessionWindowCreateFormValidationField
  ) -> String? {
    guard validationResult?.field == field else { return nil }
    return validationResult?.message
  }

  func clearValidationIfNeeded(title: String?, runtime: String?) {
    switch validationResult?.field {
    case .name where title != nil:
      validationResult = nil
    case .capability where runtime != nil:
      validationResult = nil
    case .form, .name, .capability, nil:
      break
    }
  }

  func focusValidationField(_ field: SessionWindowCreateFormValidationField) {
    if field == .name {
      focusedField = .name
    }
  }
}
