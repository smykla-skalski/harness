import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  private struct AgentCreationContext {
    let personaID: String?
    let selectedRole: SessionRole
    let fallbackRole: SessionRole?
  }

  @MainActor
  func submit() async {
    if draft.kind == .agent {
      await SessionWindowCreateFormCatalogs.loadAgentCatalogStateIfNeeded(
        store: store,
        state: state,
        draft: draft
      )
    }
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
    let resolvedSelection = SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentCapabilityOptions,
      didPickLaunchSelectionManually: state.didPickCreateLaunchSelectionManually(
        for: draft.kind
      )
    )
    let context = agentCreationContext(selection: resolvedSelection)
    switch resolvedSelection {
    case .codex:
      await createCodexAgent(
        named: name,
        selection: resolvedSelection,
        context: context
      )
    case .tui(let runtime):
      await createTuiAgent(
        named: name,
        runtime: runtime,
        selection: resolvedSelection,
        context: context
      )
    case .acp(let descriptorID):
      await createAcpAgent(
        named: name,
        descriptorID: descriptorID,
        selection: resolvedSelection,
        context: context
      )
    }
  }

  private func agentCreationContext(selection: AgentLaunchSelection) -> AgentCreationContext {
    let trimmedPersonaID = draft.personaID.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedRole = draft.role
    let fallbackRole =
      SessionWindowCreateFormCatalogs.shouldShowAcpFallbackRole(
        selection: selection,
        role: selectedRole
      ) ? draft.fallbackRole : nil
    return AgentCreationContext(
      personaID: trimmedPersonaID.isEmpty ? nil : trimmedPersonaID,
      selectedRole: selectedRole,
      fallbackRole: fallbackRole
    )
  }

  @MainActor
  private func createCodexAgent(
    named name: String,
    selection: AgentLaunchSelection,
    context: AgentCreationContext
  ) async {
    let catalog = SessionWindowCreateFormCatalogs.codexModelCatalog(
      catalogState: state.agentCreateCatalog
    )
    let pickerValue = codexModelPickerSelection.wrappedValue
    let modelSelection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: pickerValue,
      customValue: codexCustomModel.wrappedValue,
      catalogDefault: catalog?.default ?? ""
    )
    let effortValues = codexEffortValues
    let trimmedEffort = draft.codexEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    let effort =
      trimmedEffort.isEmpty
      ? SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
      : trimmedEffort
    let capabilities = capabilities(for: selection)
    guard
      let created = await store.startCodexRunSnapshot(
        prompt: draft.prompt,
        mode: draft.codexMode,
        role: context.selectedRole,
        fallbackRole: context.fallbackRole,
        capabilities: capabilities,
        name: name,
        persona: context.personaID,
        model: modelSelection.id,
        effort: effort.isEmpty ? nil : effort,
        allowCustomModel: modelSelection.allowCustomModel,
        sessionID: draft.sessionID
      )
    else {
      return
    }
    writeCodexLaunchPreset(
      selection: selection,
      role: context.selectedRole,
      mode: draft.codexMode,
      model: modelSelection.allowCustomModel ? nil : modelSelection.id,
      customModel: modelSelection.allowCustomModel ? modelSelection.id : nil,
      effort: effort.isEmpty ? nil : effort,
      fallbackRole: context.fallbackRole,
      personaID: context.personaID
    )
    state.resetCreateDraft(.agent)
    if let sessionAgentID = created.sessionAgentID {
      state.selectAgent(sessionAgentID)
    } else {
      state.selectRoute(.agents)
    }
  }

  @MainActor
  private func createTuiAgent(
    named name: String,
    runtime: AgentTuiRuntime,
    selection: AgentLaunchSelection,
    context: AgentCreationContext
  ) async {
    let pickerValue =
      draft.modelByRuntime[runtime.rawValue]
      ?? SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .tui(runtime),
        catalogState: state.agentCreateCatalog
      )?.default
      ?? ""
    let customValue = draft.customModelByRuntime[runtime.rawValue] ?? ""
    let catalogDefault =
      SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .tui(runtime),
        catalogState: state.agentCreateCatalog
      )?.default ?? ""
    let modelSelection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: pickerValue,
      customValue: customValue,
      catalogDefault: catalogDefault
    )
    let effortValues =
      SessionWindowCreateFormCatalogs.selectedModelCatalog(
        selection: .tui(runtime),
        catalogState: state.agentCreateCatalog
      ).map {
        SessionWindowCreateFormCatalogs.effortValues(
          catalog: $0,
          selectedModelID: pickerValue
        )
      }
      ?? (pickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        ? SessionWindowCreateFormCatalogs.allEffortLevels : [])
    let trimmedEffort =
      draft.effortByRuntime[runtime.rawValue]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effort =
      trimmedEffort.isEmpty
      ? SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
      : trimmedEffort
    guard
      let created = await store.startAgentTuiSnapshot(
        runtime: runtime,
        role: context.selectedRole,
        name: name,
        prompt: draft.prompt,
        persona: context.personaID,
        model: modelSelection.id,
        effort: effort.isEmpty ? nil : effort,
        allowCustomModel: modelSelection.allowCustomModel,
        argv: draft.normalizedArgvOverride,
        rows: 32,
        cols: 120,
        sessionID: draft.sessionID
      )
    else {
      return
    }
    writeTerminalLaunchPreset(
      selection: selection,
      role: context.selectedRole,
      modelByRuntime: pickerValue.isEmpty ? [:] : [runtime.rawValue: pickerValue],
      customModelByRuntime: customValue.isEmpty ? [:] : [runtime.rawValue: customValue],
      effortByRuntime: effort.isEmpty ? [:] : [runtime.rawValue: effort],
      personaID: context.personaID
    )
    state.resetCreateDraft(.agent)
    state.selectAgent(created.agentId)
  }

  @MainActor
  private func createAcpAgent(
    named name: String,
    descriptorID: String,
    selection: AgentLaunchSelection,
    context: AgentCreationContext
  ) async {
    let catalog = SessionWindowCreateFormCatalogs.selectedModelCatalog(
      selection: selection,
      catalogState: state.agentCreateCatalog
    )
    let runtimeKey = catalog?.runtime ?? descriptorID
    let pickerValue = draft.modelByRuntime[runtimeKey] ?? catalog?.default ?? ""
    let customValue = draft.customModelByRuntime[runtimeKey] ?? ""
    let catalogDefault = catalog?.default ?? ""
    let modelSelection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: pickerValue,
      customValue: customValue,
      catalogDefault: catalogDefault
    )
    let effortValues =
      catalog.map {
        SessionWindowCreateFormCatalogs.effortValues(
          catalog: $0,
          selectedModelID: pickerValue
        )
      }
      ?? (pickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        ? SessionWindowCreateFormCatalogs.allEffortLevels : [])
    let trimmedEffort =
      draft.effortByRuntime[runtimeKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effort =
      trimmedEffort.isEmpty
      ? SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
      : trimmedEffort
    let capabilities = capabilities(for: .acp(descriptorID))
    guard
      let created = await store.startAcpAgent(
        agentID: descriptorID,
        role: context.selectedRole,
        fallbackRole: context.fallbackRole,
        capabilities: capabilities,
        name: name,
        prompt: draft.prompt,
        persona: context.personaID,
        model: modelSelection.id,
        effort: effort.isEmpty ? nil : effort,
        allowCustomModel: modelSelection.allowCustomModel,
        sessionID: draft.sessionID
      )
    else {
      return
    }
    writeTerminalLaunchPreset(
      selection: selection,
      role: context.selectedRole,
      modelByRuntime: pickerValue.isEmpty ? [:] : [runtimeKey: pickerValue],
      customModelByRuntime: customValue.isEmpty ? [:] : [runtimeKey: customValue],
      effortByRuntime: effort.isEmpty ? [:] : [runtimeKey: effort],
      fallbackRole: context.fallbackRole,
      personaID: context.personaID
    )
    state.resetCreateDraft(.agent)
    state.selectAgent(created.agentId)
  }

  @MainActor
  private func writeCodexLaunchPreset(
    selection: AgentLaunchSelection,
    role: SessionRole,
    mode: CodexRunMode,
    model: String? = nil,
    customModel: String? = nil,
    effort: String? = nil,
    fallbackRole: SessionRole? = nil,
    personaID: String? = nil
  ) {
    HarnessMonitorAgentLaunchDefaults.persist(selection)
    LaunchPresetDefaults.write(
      LaunchPresetSnapshot(
        mode: .codex,
        providerStorageKey: selection.storageKey,
        role: role.rawValue,
        fallbackRole: fallbackRole?.rawValue,
        personaID: personaID,
        codexMode: mode.rawValue,
        codexModel: model,
        customCodexModel: customModel,
        codexEffort: effort
      )
    )
  }

  @MainActor
  private func writeTerminalLaunchPreset(
    selection: AgentLaunchSelection,
    role: SessionRole,
    modelByRuntime: [String: String] = [:],
    customModelByRuntime: [String: String] = [:],
    effortByRuntime: [String: String] = [:],
    fallbackRole: SessionRole? = nil,
    personaID: String? = nil
  ) {
    HarnessMonitorAgentLaunchDefaults.noteExplicitSelection(selection)
    LaunchPresetDefaults.write(
      LaunchPresetSnapshot(
        mode: .terminal,
        providerStorageKey: selection.storageKey,
        role: role.rawValue,
        fallbackRole: fallbackRole?.rawValue,
        personaID: personaID,
        modelByRuntime: modelByRuntime,
        customModelByRuntime: customModelByRuntime,
        effortByRuntime: effortByRuntime,
        rows: 32,
        cols: 120
      )
    )
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

  func clearValidationIfResolved() {
    guard validationResult != nil else { return }
    validationResult = SessionWindowCreateFormValidation.result(
      for: draft,
      capabilityOptions: activeAgentCapabilityOptions
    )
  }

  func focusValidationField(_ field: SessionWindowCreateFormValidationField) {
    if field == .name {
      focusedField = .name
    }
  }
}
