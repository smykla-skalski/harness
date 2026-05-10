import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  private var title: Binding<String> {
    Binding(
      get: { draft.title },
      set: { updateDraft(title: $0) }
    )
  }

  private var prompt: Binding<String> {
    Binding(
      get: { draft.prompt },
      set: { updateDraft(prompt: $0) }
    )
  }

  private var taskSeverity: Binding<TaskSeverity> {
    Binding(
      get: { draft.taskSeverity },
      set: { updateDraft(taskSeverity: $0) }
    )
  }

  var activeAgentCapabilityOptions: [AgentCapabilityOption] {
    SessionWindowCreateFormCatalogs.activeAgentOptions(
      catalogState: state.agentCreateCatalog,
      store: store
    )
  }

  private var catalogState: SessionWindowAgentCreateCatalogState {
    state.agentCreateCatalog
  }

  private var activePersonas: [AgentPersona] {
    catalogState.personas
  }

  private var normalizedLaunchSelection: AgentLaunchSelection {
    SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentCapabilityOptions
    )
  }

  private var selectedCapabilityOption: AgentCapabilityOption? {
    SessionWindowCreateFormCatalogs.selectedCapabilityOption(
      selection: normalizedLaunchSelection,
      options: activeAgentCapabilityOptions
    )
  }

  private var selectedTransportChoice: AgentCapabilityTransportChoice? {
    selectedCapabilityOption.map { option in
      option.transportChoice(for: normalizedLaunchSelection)
    }
  }

  private var selectedProviderID: Binding<String> {
    Binding(
      get: { selectedCapabilityOption?.id ?? "" },
      set: { newValue in
        guard
          let option = activeAgentCapabilityOptions.first(where: { $0.id == newValue })
        else {
          return
        }
        selectProvider(option)
      }
    )
  }

  private var selectedTerminalRuntime: AgentTuiRuntime? {
    guard case .tui(let runtime) = normalizedLaunchSelection else { return nil }
    return runtime
  }

  private var selectedTerminalCatalog: RuntimeModelCatalog? {
    guard let selectedTerminalRuntime else { return nil }
    return SessionWindowCreateFormCatalogs.selectedModelCatalog(
      selection: .tui(selectedTerminalRuntime),
      catalogState: catalogState
    )
  }

  private var codexCatalog: RuntimeModelCatalog? {
    SessionWindowCreateFormCatalogs.codexModelCatalog(catalogState: catalogState)
  }

  private var showsAcpFallbackRoleMenu: Bool {
    SessionWindowCreateFormCatalogs.shouldShowAcpFallbackRole(
      selection: normalizedLaunchSelection,
      role: draft.role
    )
  }

  private var agentBridgeBannerKind: SessionCreateBridgeBannerKind? {
    guard draft.kind == .agent else { return nil }
    if normalizedLaunchSelection.isAcp {
      return store.acpUnavailable ? .acp : nil
    }
    return store.agentTuiUnavailable ? .agentTui : nil
  }

  private var launchSelection: Binding<AgentLaunchSelection> {
    Binding(
      get: { normalizedLaunchSelection },
      set: { updateDraft(runtime: $0.storageKey) }
    )
  }

  private var selectedRole: Binding<SessionRole> {
    Binding(
      get: { draft.role },
      set: { updateDraft(role: $0) }
    )
  }

  private var selectedFallbackRole: Binding<SessionRole> {
    Binding(
      get: { draft.fallbackRole },
      set: { updateDraft(fallbackRole: $0) }
    )
  }

  private var selectedPersonaID: Binding<String> {
    Binding(
      get: { draft.personaID },
      set: { updateDraft(personaID: $0) }
    )
  }

  private var projectDirOverride: Binding<String> {
    Binding(
      get: { draft.projectDir },
      set: { updateDraft(projectDir: $0) }
    )
  }

  private var argvOverrideText: Binding<String> {
    Binding(
      get: { draft.argvOverride },
      set: { updateDraft(argvOverride: $0) }
    )
  }

  private var codexMode: Binding<CodexRunMode> {
    Binding(
      get: { draft.codexMode },
      set: { updateDraft(codexMode: $0) }
    )
  }

  private var codexModelPickerSelection: Binding<String> {
    Binding(
      get: {
        if draft.codexAllowCustomModel {
          return SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        }
        let stored = draft.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
          return stored
        }
        return codexCatalog?.default ?? SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
      },
      set: { newValue in
        if newValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
          updateDraft(codexAllowCustomModel: true)
        } else {
          updateDraft(
            codexModel: newValue,
            codexAllowCustomModel: false
          )
        }
      }
    )
  }

  private var codexCustomModel: Binding<String> {
    Binding(
      get: { draft.codexAllowCustomModel ? draft.codexModel : "" },
      set: {
        updateDraft(
          codexModel: $0,
          codexAllowCustomModel: true
        )
      }
    )
  }

  private var codexEffortValues: [String] {
    guard let codexCatalog else {
      return codexModelPickerSelection.wrappedValue
        == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        ? SessionWindowCreateFormCatalogs.allEffortLevels
        : []
    }
    return SessionWindowCreateFormCatalogs.effortValues(
      catalog: codexCatalog,
      selectedModelID: codexModelPickerSelection.wrappedValue
    )
  }

  private var codexEffortSelection: Binding<String> {
    Binding(
      get: {
        let current = draft.codexEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard codexEffortValues.contains(current) else {
          return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: codexEffortValues)
        }
        return current
      },
      set: { updateDraft(codexEffort: $0) }
    )
  }
}
