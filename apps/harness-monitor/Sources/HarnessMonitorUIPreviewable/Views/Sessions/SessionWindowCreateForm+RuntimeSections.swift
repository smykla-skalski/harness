import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  @ViewBuilder var agentConfigurationSections: some View {
    terminalConfigurationSections
  }

  @ViewBuilder var embeddedAgentRuntimeSections: some View {
    Section {
      if catalogState.isLoading && !catalogState.hasLoaded {
        Label("Checking available runtimes", systemImage: "clock")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if let capabilityValidation = validationMessage(for: .capability) {
        Text(capabilityValidation)
          .scaledFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Picker("Provider", selection: selectedProviderID) {
        ForEach(activeAgentCapabilityOptions) { option in
          Text(option.title).tag(option.id)
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityLabel("Provider")
    } header: {
      Text("Provider")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(embeddedProviderDescription)
        .harnessNativeFormSectionFooter()
    }
  }

  var embeddedProviderDescription: String {
    if let option = selectedCapabilityOption, let choice = selectedTransportChoice {
      let summary = SessionWindowCreateFormCatalogs.transportSummary(option: option, choice: choice)
      return "\(summary) Finish the remaining setup in the sections below"
    }
    return
      "Choose how this agent starts. ACP is preferred when available; the remaining "
      + "form sections hold the configuration details"
  }

  @ViewBuilder var terminalConfigurationSections: some View {
    if let option = selectedCapabilityOption, option.transportChoices.count > 1 {
      terminalTransportChoicesSection(option: option)
    } else if !embedsRuntimeConfiguration, selectedCapabilityOption == nil {
      Section {
        Text("Choose a provider in the middle pane to configure this agent")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Provider")
          .harnessNativeFormSectionHeader()
      }
    }

    if normalizedLaunchSelection.isCodexNative {
      codexConfigurationSection
    } else {
      terminalRuntimeConfigurationSection
    }
    terminalSessionSection
    terminalAdvancedOverridesSection
  }

  var terminalSessionSection: some View {
    Section {
      Picker("Role", selection: selectedRole) {
        ForEach(SessionRole.allCases, id: \.self) { role in
          Text(role.title).tag(role)
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityLabel("Role")

      if showsAcpFallbackRoleMenu {
        Picker("Fallback role", selection: selectedFallbackRole) {
          ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { role in
            Text(role.title).tag(role)
          }
        }
        .pickerStyle(.menu)
        .harnessNativeFormControl()
        .accessibilityLabel("Fallback role")
      }
      Picker("Persona", selection: selectedPersonaID) {
        Text("None").tag("")
        ForEach(activePersonas, id: \.identifier) { persona in
          Text(persona.name).tag(persona.identifier)
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityLabel("Persona")
    } header: {
      Text("Session")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        SessionWindowCreateFormCatalogs.selectedPersonaStateText(
          personaID: draft.personaID,
          personas: activePersonas
        )
      )
      .harnessNativeFormSectionFooter()
    }
  }

  @ViewBuilder var terminalAdvancedOverridesSection: some View {
    if !normalizedLaunchSelection.isManagedControlPlane {
      Section {
        HarnessMonitorMultilineTextField<SessionWindowCreateFormField>(
          placeholder: "",
          text: argvOverrideText,
          minHeight: 100,
          focusedField: focusedFieldBinding,
          equals: .commandOverride,
          accessibilityLabel: "Command override"
        )
      } header: {
        Text("Advanced overrides")
          .harnessNativeFormSectionHeader()
      } footer: {
        Text(advancedOverridesDescription)
          .harnessNativeFormSectionFooter()
      }
    }
  }

  var advancedOverridesDescription: String {
    "Use one argument per line for a command override; the first line is the executable"
  }

  @ViewBuilder
  func terminalTransportChoicesSection(option: AgentCapabilityOption) -> some View {
    if option.transportChoices.count > 1 {
      Section {
        SessionWindowCreateTransportChoicesGroup(
          option: option,
          selectedSelection: normalizedLaunchSelection,
          usesVerticalLayout: fontScale >= 1.35,
          onSelectChoice: { launchSelection.wrappedValue = $0 }
        )
        .equatable()

        if let choice = selectedTransportChoice {
          terminalTransportNotice(option: option, choice: choice)
        }
      } header: {
        Text("Start with")
          .harnessNativeFormSectionHeader()
      } footer: {
        Text("Choose whether this provider opens in Terminal or joins via ACP")
          .harnessNativeFormSectionFooter()
      }
    }
  }

  @ViewBuilder var terminalRuntimeConfigurationSection: some View {
    let option = selectedCapabilityOption
    let choice = selectedTransportChoice

    Section {
      if let catalog = selectedRuntimeCatalog,
        let runtimeKey = selectedModelCatalogRuntimeKey
      {
        let modelPickerValue =
          if isOpenRouterAcpSelected {
            currentOpenRouterModelPickerValue(for: runtimeKey)
          } else {
            currentRuntimeModelPickerValue(for: runtimeKey, catalog: catalog)
          }
        let effortValues =
          if isOpenRouterAcpSelected {
            SessionWindowCreateFormCatalogs.effortValues(
              catalog: catalog,
              selectedModelID: modelPickerValue
            )
          } else {
            runtimeEffortValues(for: runtimeKey, catalog: catalog)
          }
        if isOpenRouterAcpSelected {
          openRouterPickerView(runtimeKey: runtimeKey)
        } else {
          SessionWindowCreateRuntimeModelPickerRow(
            catalog: catalog,
            modelPickerValue: modelPickerValue,
            onModelChange: { updateRuntimeModelPickerSelection($0, for: runtimeKey) }
          )
          .equatable()
        }

        if modelPickerValue == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
          SessionWindowCreateRuntimeCustomModelRow(
            customModel: currentRuntimeCustomModel(for: runtimeKey),
            onCustomModelChange: { updateRuntimeCustomModel($0, for: runtimeKey) }
          )
          .equatable()
        }

        if !effortValues.isEmpty {
          SessionWindowCreateRuntimeEffortRow(
            values: effortValues,
            selectedEffort: resolvedRuntimeEffortSelection(
              for: runtimeKey,
              values: effortValues
            ),
            onEffortChange: { updateRuntimeEffort($0, for: runtimeKey) }
          )
          .equatable()
        }
      } else if normalizedLaunchSelection.isAcp {
        Text("ACP uses the provider's configured defaults")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("This runtime does not publish additional model controls here")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let option, let choice, option.transportChoices.count <= 1 {
        terminalTransportNotice(option: option, choice: choice)
      }
    } header: {
      Text("Runtime")
        .harnessNativeFormSectionHeader()
    } footer: {
      if let option, let choice {
        Text(SessionWindowCreateFormCatalogs.transportSummary(option: option, choice: choice))
          .harnessNativeFormSectionFooter()
      }
    }
  }

  @ViewBuilder
  func openRouterPickerView(
    runtimeKey: String
  ) -> some View {
    let selectionBinding = Binding<String>(
      get: { currentOpenRouterModelPickerValue(for: runtimeKey) },
      set: { updateRuntimeModelPickerSelection($0, for: runtimeKey) }
    )
    let useCustomBinding = Binding<Bool>(
      get: {
        currentOpenRouterModelPickerValue(for: runtimeKey)
          == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
      },
      set: { newValue in
        if newValue {
          updateRuntimeModelPickerSelection(
            SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag,
            for: runtimeKey
          )
        }
      }
    )
    if isLoadingOpenRouterModels, openRouterModels.isEmpty {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading model catalog from OpenRouter…")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    } else {
      OpenRouterModelPicker(
        availableModels: openRouterModels,
        usageSnapshot: openRouterUsageSnapshot,
        selectedModelID: selectionBinding,
        useCustomModel: useCustomBinding,
        onBrowseAll: { isPresentingOpenRouterBrowser = true }
      )
    }
  }
}
