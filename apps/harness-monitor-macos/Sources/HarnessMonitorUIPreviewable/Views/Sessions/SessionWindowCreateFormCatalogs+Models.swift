import Foundation
import HarnessMonitorKit

extension SessionWindowCreateFormCatalogs {
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
    if choice.id.isCodexNative {
      return option.requiresCodexBridgeAccess
        ? "Codex requires bridge setup. Open setup details below"
        : nil
    }

    guard case .acp = choice.id else {
      return nil
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return nil
    case .checkingAccess:
      return "ACP is still being checked"
    case .setupRequired:
      if option.bundledWithHarness {
        return "ACP ships with Harness. Install or update Harness to enable it here"
      }
      return "ACP requires CLI setup. Copy install instructions below"
    case .bridgeAccessRequired:
      return "ACP requires bridge setup. Open setup details below"
    case .terminalOnly:
      return "ACP isn't available for this provider yet"
    case .unavailable:
      return
        option.projectAccessGuidanceText
        ?? "ACP isn't available for this provider yet"
    }
  }

  static func shouldShowAcpFallbackRole(
    selection: AgentLaunchSelection,
    role: SessionRole
  ) -> Bool {
    selection.isManagedControlPlane && role == .leader
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
      return "No persona selected"
    }

    return "Using \(persona.name)"
  }

  @MainActor
  static func normalizedLaunchSelection(
    draft: SessionCreateDraft,
    options: [AgentCapabilityOption],
    didPickLaunchSelectionManually: Bool = false,
    userDefaults: UserDefaults = .standard
  ) -> AgentLaunchSelection {
    let selection: AgentLaunchSelection
    if didPickLaunchSelectionManually {
      selection = draft.launchSelection
    } else {
      selection = resolvedInitialLaunchSelection(
        draft: draft,
        options: options,
        userDefaults: userDefaults
      )
    }
    return AgentCapabilityCatalog.normalizedLaunchSelection(
      options: options,
      selection: selection,
      fallbackRuntime: selection.preferredRuntime
    )
  }

  @MainActor
  static func resolvedInitialLaunchSelection(
    draft: SessionCreateDraft,
    options: [AgentCapabilityOption],
    userDefaults: UserDefaults = .standard
  ) -> AgentLaunchSelection {
    if let preferredProviderID = HarnessMonitorAgentLaunchDefaults.preferredProviderID(
      userDefaults: userDefaults
    ) {
      return AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: preferredProviderID,
        options: options,
        fallback: draft.launchSelection
      )
    }

    if let snapshot = LaunchPresetDefaults.read(userDefaults: userDefaults),
      LaunchPresetDefaults.blocksInitialAcpDefault(snapshot),
      let providerID = snapshot.providerID
    {
      return AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: providerID,
        options: options,
        fallback: draft.launchSelection
      )
    }

    return AgentCapabilityCatalog.firstProviderLaunchSelection(options: options)
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
    case .codex:
      return codexModelCatalog(catalogState: catalogState)
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

  static func normalizedRuntimeModelPickerValue(
    storedValue: String?,
    catalog: RuntimeModelCatalog
  ) -> String {
    normalizedModelPickerValue(
      storedValue: storedValue,
      validModelIDs: catalog.models.map(\.id),
      preferredDefault: catalog.default
    )
  }

  static func normalizedOpenRouterModelPickerValue(
    storedValue: String?,
    availableModels: [OpenRouterModelEntry],
    preferredDefault: String = OpenRouterAcpDispatch.defaultModel
  ) -> String {
    normalizedModelPickerValue(
      storedValue: storedValue,
      validModelIDs: availableModels.map(\.id),
      preferredDefault: preferredDefault
    )
  }

  private static func normalizedModelPickerValue(
    storedValue: String?,
    validModelIDs: [String],
    preferredDefault: String
  ) -> String {
    let trimmedStored =
      storedValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedStored == RuntimeCustomModel.tag {
      return RuntimeCustomModel.tag
    }

    let trimmedIDs =
      validModelIDs
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let validIDs = Set(trimmedIDs)
    if let trimmedStored, !trimmedStored.isEmpty, validIDs.contains(trimmedStored) {
      return trimmedStored
    }

    let trimmedDefault = preferredDefault.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedDefault.isEmpty, validIDs.contains(trimmedDefault) {
      return trimmedDefault
    }

    if let firstValid = trimmedIDs.first {
      return firstValid
    }

    return RuntimeCustomModel.tag
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
