import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
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
      if draft.useCodex {
        await createCodexRun(named: name)
      } else {
        await createAgent(named: name)
      }
    case .task:
      await createTask(named: name)
    case .decision:
      await createDecision(summary: name)
    }
  }

  @MainActor
  func createCodexRun(named name: String) async {
    let trimmedPrompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let codexCatalog = SessionWindowCreateFormCatalogs.codexModelCatalog(
      catalogState: state.agentCreateCatalog
    )
    let pickerValue: String = {
      if draft.codexAllowCustomModel {
        return SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
      }
      let stored = draft.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !stored.isEmpty {
        return stored
      }
      return codexCatalog?.default ?? ""
    }()
    let modelSelection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: pickerValue,
      customValue: draft.codexAllowCustomModel ? draft.codexModel : "",
      catalogDefault: codexCatalog?.default ?? ""
    )
    let effortValues =
      codexCatalog.map {
        SessionWindowCreateFormCatalogs.effortValues(
          catalog: $0,
          selectedModelID: pickerValue
        )
      } ?? (
        pickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
          ? SessionWindowCreateFormCatalogs.allEffortLevels : []
      )
    let trimmedEffort = draft.codexEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    let effort =
      trimmedEffort.isEmpty
      ? SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
      : trimmedEffort
    guard
      let started = await store.startCodexRunSnapshot(
        prompt: trimmedPrompt,
        mode: draft.codexMode,
        model: modelSelection.id,
        effort: effort.isEmpty ? nil : effort,
        allowCustomModel: modelSelection.allowCustomModel,
        sessionID: draft.sessionID
      )
    else {
      return
    }
    _ = name
    LaunchPresetDefaults.write(
      LaunchPresetSnapshot(
        mode: .codex,
        codexMode: draft.codexMode.rawValue,
        codexModel:
          pickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag ? nil : modelSelection.id,
        customCodexModel: modelSelection.allowCustomModel ? modelSelection.id : nil,
        codexEffort: effort.isEmpty ? nil : effort
      )
    )
    state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
    state.select(.codexRun(sessionID: draft.sessionID, runID: started.runId))
  }

  @MainActor
  func createAgent(named name: String) async {
    let resolvedSelection = SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentCapabilityOptions
    )
    let trimmedProjectDir = draft.projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
    let projectDir = trimmedProjectDir.isEmpty ? nil : trimmedProjectDir
    let trimmedPersonaID = draft.personaID.trimmingCharacters(in: .whitespacesAndNewlines)
    let personaID = trimmedPersonaID.isEmpty ? nil : trimmedPersonaID
    let selectedRole = draft.role
    let fallbackRole =
      SessionWindowCreateFormCatalogs.shouldShowAcpFallbackRole(
        selection: resolvedSelection,
        role: selectedRole
      ) ? draft.fallbackRole : nil
    switch resolvedSelection {
    case .tui(let runtime):
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
        } ?? (
          pickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
            ? SessionWindowCreateFormCatalogs.allEffortLevels : []
        )
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
          role: selectedRole,
          name: name,
          prompt: draft.prompt,
          projectDir: projectDir,
          persona: personaID,
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
        selection: resolvedSelection,
        role: selectedRole,
        modelByRuntime:
          pickerValue.isEmpty ? [:] : [runtime.rawValue: pickerValue],
        customModelByRuntime:
          customValue.isEmpty ? [:] : [runtime.rawValue: customValue],
        effortByRuntime:
          effort.isEmpty ? [:] : [runtime.rawValue: effort],
        personaID: personaID
      )
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    case .acp(let descriptorID):
      let capabilities = capabilities(for: .acp(descriptorID))
      guard
        let created = await store.startAcpAgent(
          agentID: descriptorID,
          role: selectedRole,
          fallbackRole: fallbackRole,
          capabilities: capabilities,
          name: name,
          prompt: draft.prompt,
          projectDir: projectDir,
          persona: personaID,
          sessionID: draft.sessionID
        )
      else {
        return
      }
      writeTerminalLaunchPreset(
        selection: resolvedSelection,
        role: selectedRole,
        fallbackRole: fallbackRole,
        personaID: personaID
      )
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    }
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

  func clearValidationIfNeeded(title: String?, runtime: String?, useCodex: Bool? = nil) {
    switch validationResult?.field {
    case .name where title != nil:
      validationResult = nil
    case .capability where runtime != nil || useCodex != nil:
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
