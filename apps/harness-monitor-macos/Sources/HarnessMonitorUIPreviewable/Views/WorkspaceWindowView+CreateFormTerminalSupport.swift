import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  var selectedAgentLaunchTitle: String {
    switch viewModel.selectedLaunchSelection {
    case .tui(let runtime):
      runtime.title
    case .acp(let id):
      viewModel.availableAcpAgents.first { $0.id == id }?.displayName ?? "Agent"
    }
  }

  var agentCapabilityOptions: [AgentCapabilityOption] {
    WorkspaceWindowView.agentCapabilityOptions(
      acpAgents: viewModel.availableAcpAgents,
      runtimeProbeResults: viewModel.runtimeProbeResults,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready
    )
  }

  var showsAcpFallbackRoleMenu: Bool {
    viewModel.selectedLaunchSelection.isAcp && viewModel.selectedRole == .leader
  }

  var selectedCapabilityOption: AgentCapabilityOption? {
    agentCapabilityOptions.first { option in
      option.transportChoices.contains { $0.id == viewModel.selectedLaunchSelection }
    } ?? agentCapabilityOptions.first
  }

  func installHintText(for option: AgentCapabilityOption) -> String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  func unavailableReason(
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
      return "Project access requires bridge setup. Open setup details below."
    case .terminalOnly:
      return "Project access isn't available for this provider yet."
    case .unavailable:
      return
        option.projectAccessGuidanceText
        ?? "Project access isn't available for this provider yet."
    }
  }

  func transportSummary(
    for option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String {
    if choice.id.isAcp {
      return "Starts with project access available."
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Opens in Terminal. Project access is also available."
    case .checkingAccess:
      return "Opens in Terminal while project access is checked."
    case .setupRequired:
      return "Opens in Terminal. Set up project access when you're ready."
    case .bridgeAccessRequired:
      return "Opens in Terminal. Turn on bridge access to use project access."
    case .terminalOnly:
      return "Opens in Terminal."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider isn't available yet."
    }
  }

  var roleAndPersonaSection: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        roleMenu
        if showsAcpFallbackRoleMenu {
          acpFallbackRoleMenu
        }
        personaMenu
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        roleMenu
        if showsAcpFallbackRoleMenu {
          acpFallbackRoleMenu
        }
        personaMenu
      }
    }
  }

  @ViewBuilder
  func terminalTransportChoicesSection(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    if option.transportChoices.count > 1 {
      AgentsCreateFieldBlock(
        title: "Start with",
        help: "Choose whether this provider opens in Terminal or joins with project access."
      ) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(option.transportChoices) { transportChoice in
            AgentsCreateTransportChoiceButton(
              providerTitle: option.title,
              optionID: option.id,
              choice: transportChoice,
              selection: context.selection,
              isSelected: context.normalizedSelection == transportChoice.id,
              isEnabled: option.isEnabled(transportChoice),
              unavailableReason: unavailableReason(for: option, choice: transportChoice)
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  func terminalTransportNotice(
    option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> some View {
    if let unavailableReason = unavailableReason(for: option, choice: choice),
      !option.isEnabled(choice)
    {
      Label {
        Text(unavailableReason)
          .scaledFont(.caption)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .foregroundStyle(HarnessMonitorTheme.caution)
      .accessibilityElement(children: .combine)
    }

    if option.showsInstallCTA {
      let installButtonID = HarnessMonitorAccessibility.agentCapabilityInstallButton(option.id)
      HarnessMonitorActionButton(
        title: option.installActionTitle,
        tint: .orange,
        variant: .prominent,
        accessibilityIdentifier: installButtonID,
        fillsWidth: false
      ) {
        HarnessMonitorClipboard.copy(installHintText(for: option))
      }
      .help(installHintText(for: option))
      .accessibilityHint(option.installAccessibilityHint ?? "")
    }

    if option.availabilityState == .checkingAccess
      || option.availabilityState == .setupRequired
      || option.availabilityState == .bridgeAccessRequired
      || option.availabilityState == .unavailable
    {
      AgentsCreateDiagnosticsDisclosure(option: option)
        .id(option.id)
    }
  }

  func terminalModelField(context: TerminalConfigurationContext) -> some View {
    AgentsCreateFieldBlock(
      title: "Model",
      help: "Choose the default model for the selected provider."
    ) {
      Picker(selectedTerminalModelMenuTitle(context: context), selection: context.modelBinding) {
        ForEach(context.catalogModels) { model in
          Text(model.displayName)
            .tag(model.id)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.agentsModelPicker,
                option: model.displayName
              )
            )
        }
        Text("Custom...")
          .tag(RuntimeCustomModel.tag)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.agentsModelPicker,
              option: "Custom"
            )
          )
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsModelPicker).frame")
      .accessibilityLabel("Model")
      .harnessMCPButton(HarnessMonitorAccessibility.agentsModelPicker, label: "Model")

      Text(selectedTerminalModelStateText(context: context))
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)

      if context.modelBinding.wrappedValue == RuntimeCustomModel.tag {
        TextField("Provider-specific model id", text: context.customModelBinding)
          .harnessNativeFormControl()
          .harnessMCPTextField(
            HarnessMonitorAccessibility.agentsCustomModelField,
            label: "Provider-specific model id",
            value: context.customModelBinding.wrappedValue
          )
      }
    }
  }

  func selectedTerminalModelStateText(context: TerminalConfigurationContext) -> String {
    let selectedModelID = context.modelBinding.wrappedValue
    if selectedModelID == RuntimeCustomModel.tag {
      let customModelID = context.customModelBinding.wrappedValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if customModelID.isEmpty {
        return "Custom model selected. Enter the provider-specific id below."
      }
      return "Using custom model \(customModelID)."
    }

    let displayName =
      context.catalogModels.first { $0.id == selectedModelID }?.displayName ?? selectedModelID
    return "Using \(displayName)."
  }

  func selectedTerminalModelMenuTitle(context: TerminalConfigurationContext) -> String {
    let selectedModelID = context.modelBinding.wrappedValue
    if selectedModelID == RuntimeCustomModel.tag {
      let customModelID = context.customModelBinding.wrappedValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      return customModelID.isEmpty ? "Custom model" : customModelID
    }

    return
      context.catalogModels.first { $0.id == selectedModelID }?.displayName
      ?? selectedModelID
  }

  var selectedPersonaStateText: String {
    guard
      let selectedPersona = viewModel.selectedPersona,
      let personaName =
        viewModel.availablePersonas.first(where: { $0.identifier == selectedPersona })?.name
    else {
      return "No persona selected."
    }

    return "Using \(personaName)."
  }

  var canStartTerminal: Bool {
    guard !viewModel.isSubmitting, createPaneSessionActionUnavailableNote == nil else {
      return false
    }
    switch viewModel.selectedLaunchSelection {
    case .tui:
      return viewModel.rows > 0 && viewModel.cols > 0
    case .acp(let id):
      guard
        let option = agentCapabilityOptions.first(where: { option in
          option.transportChoices.contains { $0.id == .acp(id) }
        })
      else {
        return false
      }
      return option.isEnabled(option.transportChoice(for: .acp(id)))
    }
  }

  @ViewBuilder
  func terminalEffortField(context: TerminalConfigurationContext) -> some View {
    if !context.effortValues.isEmpty {
      AgentsCreateFieldBlock(
        title: "Effort",
        help: "Reasoning effort only appears for models that expose it."
      ) {
        Picker("Effort", selection: context.effortBinding) {
          ForEach(Array(context.effortValues.enumerated()), id: \.offset) { _, level in
            Text(level.capitalized)
              .tag(level)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.agentsEffortPicker,
                  option: level
                )
              )
          }
        }
        .pickerStyle(.segmented)
        .harnessNativeFormControl()
        .harnessMCPButton(HarnessMonitorAccessibility.agentsEffortPicker, label: "Effort")
      }
    }
  }

  func terminalSizeStepper(
    title: String,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    step: Int = 1
  ) -> some View {
    AgentsCreateFieldBlock(title: title) {
      Stepper(
        title == "Rows" ? "Rows \(value.wrappedValue)" : "Cols \(value.wrappedValue)",
        value: value,
        in: range,
        step: step
      )
      .harnessNativeFormControl()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func terminalConfigurationContext(
    for option: AgentCapabilityOption
  ) -> TerminalConfigurationContext {
    @Bindable var formModel = viewModel
    let normalizedSelection = option.normalizedSelection(for: formModel.selectedLaunchSelection)
    let choice = option.transportChoice(for: normalizedSelection)
    let selectedRuntime = normalizedSelection.preferredRuntime
    let catalog = formModel.availableRuntimeModels.first { $0.runtime == selectedRuntime.rawValue }
    let modelBinding = Binding<String>(
      get: {
        formModel.selectedTerminalModelByRuntime[selectedRuntime]
          ?? catalog?.default ?? RuntimeCustomModel.tag
      },
      set: { formModel.selectedTerminalModelByRuntime[selectedRuntime] = $0 }
    )
    let customModelBinding = Binding<String>(
      get: { formModel.customTerminalModelByRuntime[selectedRuntime] ?? "" },
      set: { formModel.customTerminalModelByRuntime[selectedRuntime] = $0 }
    )
    let effortValues =
      catalog
      .map {
        WorkspaceWindowView.effortValues(
          catalog: $0,
          selectedModelId: modelBinding.wrappedValue
        )
      }
      ?? WorkspaceWindowView.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedTerminalEffortByRuntime[selectedRuntime],
          effortValues.contains(current)
        else {
          return WorkspaceWindowView.defaultEffortLevel(from: effortValues)
        }
        return current
      },
      set: { formModel.selectedTerminalEffortByRuntime[selectedRuntime] = $0 }
    )

    return TerminalConfigurationContext(
      choice: choice,
      normalizedSelection: normalizedSelection,
      selection: $formModel.selectedLaunchSelection,
      catalogModels: catalog?.models ?? [],
      modelBinding: modelBinding,
      customModelBinding: customModelBinding,
      effortValues: effortValues,
      effortBinding: effortBinding
    )
  }
}

struct TerminalConfigurationContext {
  let choice: AgentCapabilityTransportChoice
  let normalizedSelection: AgentLaunchSelection
  let selection: Binding<AgentLaunchSelection>
  let catalogModels: [RuntimeModel]
  let modelBinding: Binding<String>
  let customModelBinding: Binding<String>
  let effortValues: [String]
  let effortBinding: Binding<String>
}
