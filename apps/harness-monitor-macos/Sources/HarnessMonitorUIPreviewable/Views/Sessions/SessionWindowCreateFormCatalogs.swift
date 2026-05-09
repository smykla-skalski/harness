import HarnessMonitorKit

enum SessionWindowCreateFormCatalogs {
  enum RuntimeCustomModel {
    static let tag = "__custom__"
  }

  static let allEffortLevels: [String] = ["off", "low", "medium", "high", "xhigh"]

  @MainActor
  static func fallbackAgentOptions(store: HarnessMonitorStore) -> [AgentCapabilityOption] {
    AgentCapabilityCatalog.options(
      acpAgents: [],
      runtimeProbeResults: nil,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )
  }

  @MainActor
  static func loadAgentCatalogState(
    store: HarnessMonitorStore
  ) async -> SessionWindowAgentCreateCatalogState {
    async let acpAgents = store.fetchAcpAgentDescriptors()
    async let runtimeProbeResults = store.fetchRuntimeProbeResults()
    async let runtimeModelCatalogs = store.fetchRuntimeModelCatalogs()
    async let personas = store.fetchPersonas()

    let descriptors = await acpAgents
    let probes = await runtimeProbeResults
    let runtimeModels = await runtimeModelCatalogs
    let availablePersonas = await personas

    return SessionWindowAgentCreateCatalogState(
      descriptors: descriptors,
      runtimeModelCatalogs: runtimeModels,
      capabilityOptions: AgentCapabilityCatalog.options(
        acpAgents: descriptors,
        runtimeProbeResults: probes,
        sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
        acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
      ),
      personas: availablePersonas,
      isLoading: false,
      hasLoaded: true
    )
  }

  @MainActor
  static func loadAgentCatalogStateIfNeeded(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    draft: SessionCreateDraft
  ) async {
    guard draft.kind == .agent else { return }
    if state.agentCreateCatalog.hasLoaded {
      normalizeDraftIfNeeded(store: store, state: state, draft: draft)
      return
    }

    if !state.beginAgentCreateCatalogLoading() {
      while state.agentCreateCatalog.isLoading {
        await Task.yield()
      }
      normalizeDraftIfNeeded(store: store, state: state, draft: draft)
      return
    }

    let catalogState = await loadAgentCatalogState(store: store)
    state.finishAgentCreateCatalogLoading(
      descriptors: catalogState.descriptors,
      runtimeModelCatalogs: catalogState.runtimeModelCatalogs,
      capabilityOptions: catalogState.capabilityOptions,
      personas: catalogState.personas
    )
    normalizeDraftIfNeeded(store: store, state: state, draft: draft)
  }

  @MainActor
  static func normalizeDraftIfNeeded(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    draft: SessionCreateDraft
  ) {
    let options = activeAgentOptions(catalogState: state.agentCreateCatalog, store: store)
    let normalized = normalizedLaunchSelection(draft: draft, options: options)
    guard normalized.storageKey != draft.launchSelection.storageKey else {
      return
    }
    var next = draft
    next.runtime = normalized.storageKey
    state.updateCreateDraft(next)
  }

  @MainActor
  static func activeAgentOptions(
    catalogState: SessionWindowAgentCreateCatalogState,
    store: HarnessMonitorStore
  ) -> [AgentCapabilityOption] {
    catalogState.capabilityOptions.isEmpty
      ? fallbackAgentOptions(store: store)
      : catalogState.capabilityOptions
  }

  static func transportSummary(
    option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String {
    if choice.id.isAcp {
      return "Starts with project access."
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Opens in Terminal. Project access is also available."
    case .checkingAccess:
      return "Opens in Terminal while project access is being checked."
    case .setupRequired:
      return "Opens in Terminal. Set up project access when you're ready."
    case .bridgeAccessRequired:
      return "Opens in Terminal. Turn on bridge access to use project access."
    case .terminalOnly:
      return "Opens in Terminal."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider isn't available here yet."
    }
  }

  static func installHintText(for option: AgentCapabilityOption) -> String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  static func unavailableReason(
    for option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String? {
    guard case .acp = choice.id else {
      return nil
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return nil
    case .checkingAccess:
      return "Project access is still being checked."
    case .setupRequired:
      return "Project access requires CLI setup. Copy install instructions below."
    case .bridgeAccessRequired:
      return "Project access requires bridge setup."
    case .terminalOnly:
      return "Project access isn't available for this provider yet."
    case .unavailable:
      return
        option.projectAccessGuidanceText
        ?? "Project access isn't available for this provider yet."
    }
  }

  static func shouldShowAcpFallbackRole(
    selection: AgentLaunchSelection,
    role: SessionRole
  ) -> Bool {
    selection.isAcp && role == .leader
  }

  static func selectedPersona(
    personaID: String,
    personas: [AgentPersona]
  ) -> AgentPersona? {
    let trimmedID = personaID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      return nil
    }
    return personas.first { $0.identifier == trimmedID }
  }

  static func selectedPersonaStateText(
    personaID: String,
    personas: [AgentPersona]
  ) -> String {
    guard let persona = selectedPersona(personaID: personaID, personas: personas) else {
      return "No persona selected."
    }

    return "Using \(persona.name)."
  }

  static func normalizedLaunchSelection(
    draft: SessionCreateDraft,
    options: [AgentCapabilityOption]
  ) -> AgentLaunchSelection {
    AgentCapabilityCatalog.normalizedLaunchSelection(
      options: options,
      selection: draft.launchSelection,
      fallbackRuntime: draft.launchSelection.preferredRuntime
    )
  }

  static func selectedCapabilityOption(
    selection: AgentLaunchSelection,
    options: [AgentCapabilityOption]
  ) -> AgentCapabilityOption? {
    options.first { option in
      option.transportChoices.contains { $0.id == selection }
    } ?? options.first
  }

  static func selectedModelCatalog(
    selection: AgentLaunchSelection,
    catalogState: SessionWindowAgentCreateCatalogState
  ) -> RuntimeModelCatalog? {
    switch selection {
    case .tui(let runtime):
      return catalogState.runtimeModelCatalogs.first { $0.runtime == runtime.rawValue }
    case .acp(let descriptorID):
      if let descriptor = catalogState.descriptors.first(where: { $0.id == descriptorID }),
        let modelCatalog = descriptor.modelCatalog
      {
        return modelCatalog
      }
      if let runtime = AgentTuiRuntime(rawValue: descriptorID) {
        return catalogState.runtimeModelCatalogs.first { $0.runtime == runtime.rawValue }
      }
      return nil
    }
  }

  static func codexModelCatalog(
    catalogState: SessionWindowAgentCreateCatalogState
  ) -> RuntimeModelCatalog? {
    catalogState.runtimeModelCatalogs.first { $0.runtime == "codex" }
  }

  static func effortValues(
    catalog: RuntimeModelCatalog,
    selectedModelID: String
  ) -> [String] {
    if selectedModelID == RuntimeCustomModel.tag {
      return allEffortLevels
    }
    guard let model = catalog.models.first(where: { $0.id == selectedModelID }) else {
      return []
    }
    return model.effortValues
  }

  static func defaultEffortLevel(from values: [String]) -> String {
    guard !values.isEmpty else { return "" }
    if let medium = values.first(where: { $0 == "medium" }) {
      return medium
    }
    return values[values.count / 2]
  }

  static func effectiveModelSelection(
    pickerValue: String,
    customValue: String,
    catalogDefault: String
  ) -> (id: String?, allowCustomModel: Bool) {
    if pickerValue == RuntimeCustomModel.tag {
      let trimmed = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return (trimmed.isEmpty ? nil : trimmed, true)
    }
    if pickerValue.isEmpty {
      return (catalogDefault.isEmpty ? nil : catalogDefault, false)
    }
    return (pickerValue, false)
  }
}

extension SessionCreateDraft {
  var launchSelection: AgentLaunchSelection {
    AgentLaunchSelection(storageKey: runtime)
      ?? AgentTuiRuntime(rawValue: runtime).map(AgentLaunchSelection.tui)
      ?? HarnessMonitorAgentLaunchDefaults.startupFallbackSelection
  }
}
