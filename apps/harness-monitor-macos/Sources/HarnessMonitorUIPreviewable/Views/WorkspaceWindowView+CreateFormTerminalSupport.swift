import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  var selectedAgentLaunchTitle: String {
    selectedCapabilityOption?.title ?? "Agent"
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
      return "ACP is still being checked."
    case .setupRequired:
      return "ACP requires CLI setup. Copy install instructions below."
    case .bridgeAccessRequired:
      return "ACP requires bridge setup. Open setup details below."
    case .terminalOnly:
      return "ACP isn't available for this provider yet."
    case .unavailable:
      return
        option.projectAccessGuidanceText
        ?? "ACP isn't available for this provider yet."
    }
  }

  func transportSummary(
    for option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String {
    if choice.id.isAcp {
      return "Starts via ACP."
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Opens in Terminal. ACP is also available."
    case .checkingAccess:
      return "Opens in Terminal while ACP is checked."
    case .setupRequired:
      return "Opens in Terminal. Set up ACP when you're ready."
    case .bridgeAccessRequired:
      return "Opens in Terminal. Turn on bridge access to use ACP."
    case .terminalOnly:
      return "Opens in Terminal."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider isn't available yet."
    }
  }

  var roleAndPersonaSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      roleMenu
      if showsAcpFallbackRoleMenu {
        acpFallbackRoleMenu
      }
      personaMenu
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
        help: "Choose whether this provider opens in Terminal or joins via ACP."
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
    AgentsCreateFieldBlock(title: "Model") {
      Picker(selectedTerminalModelMenuTitle(context: context), selection: context.modelBinding) {
        ForEach(context.catalogModels) { model in
          Text(model.displayName)
            .tag(model.id)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceModelPicker,
                option: model.displayName
              )
            )
            .harnessMCPMenuItem(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceModelPicker,
                option: model.displayName
              ),
              label: model.displayName,
              pressAction: { context.modelBinding.wrappedValue = model.id }
            )
        }
        Text("Custom...")
          .tag(RuntimeCustomModel.tag)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspaceModelPicker,
              option: "Custom"
            )
          )
          .harnessMCPMenuItem(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspaceModelPicker,
              option: "Custom"
            ),
            label: "Custom",
            pressAction: { context.modelBinding.wrappedValue = RuntimeCustomModel.tag }
          )
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.workspaceModelPicker).frame")
      .accessibilityLabel("Model")
      .harnessMCPButton(HarnessMonitorAccessibility.workspaceModelPicker, label: "Model")

      if context.modelBinding.wrappedValue == RuntimeCustomModel.tag {
        TextField("Provider-specific model id", text: context.customModelBinding)
          .harnessNativeTextField()
          .harnessMCPTextField(
            HarnessMonitorAccessibility.workspaceCustomModelField,
            label: "Provider-specific model id",
            value: context.customModelBinding.wrappedValue
          )
          .harnessPreservePrimaryContentFocus()
      }
    }
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
      AgentsCreateFieldBlock(title: "Effort") {
        Picker("Effort", selection: context.effortBinding) {
          ForEach(Array(context.effortValues.enumerated()), id: \.offset) { _, level in
            Text(level.capitalized)
              .tag(level)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.workspaceEffortPicker,
                  option: level
                )
              )
              .harnessMCPButton(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.workspaceEffortPicker,
                  option: level
                ),
                label: level.capitalized,
                pressAction: { context.effortBinding.wrappedValue = level }
              )
          }
        }
        .pickerStyle(.segmented)
        .harnessNativeFormControl()
        .harnessMCPButton(HarnessMonitorAccessibility.workspaceEffortPicker, label: "Effort")
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
        "\(title) \(value.wrappedValue)",
        value: value,
        in: range,
        step: step
      )
      .harnessNativeFormControl()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  func terminalConfigPillRow(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    AgentsConfigPillFlow(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      if option.transportChoices.count > 1 {
        terminalTransportPill(option: option, context: context)
      }
      if !context.catalogModels.isEmpty {
        terminalModelPill(context: context)
      }
      if !context.effortValues.isEmpty {
        terminalEffortPill(context: context)
      }
      terminalRolePill
      if showsAcpFallbackRoleMenu {
        terminalFallbackRolePill
      }
      terminalPersonaPill
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func terminalTransportPill(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    let label = context.choice.id.isAcp ? "ACP" : "Terminal"
    return AgentsConfigPill(
      label: label,
      value: label,
      state: .set,
      accessibilityLabel: "Transport"
    ) {
      ForEach(option.transportChoices) { transportChoice in
        Button {
          context.selection.wrappedValue = transportChoice.id
        } label: {
          Text(transportChoice.id.isAcp ? "ACP" : "Terminal")
        }
        .disabled(!option.isEnabled(transportChoice))
      }
    }
  }

  private func terminalModelPill(
    context: TerminalConfigurationContext
  ) -> some View {
    let label = selectedTerminalModelMenuTitle(context: context)
    let isCatalogDefault = context.catalogModels.contains(where: {
      $0.id == context.modelBinding.wrappedValue
    })
    let state: AgentsConfigPillState =
      context.modelBinding.wrappedValue == RuntimeCustomModel.tag ? .set
      : (isCatalogDefault ? .default : .set)
    return AgentsConfigPill(
      label: label,
      value: label,
      state: state,
      accessibilityLabel: "Model"
    ) {
      ForEach(context.catalogModels) { model in
        Button(model.displayName) {
          context.modelBinding.wrappedValue = model.id
        }
      }
      Button("Custom...") {
        context.modelBinding.wrappedValue = RuntimeCustomModel.tag
      }
    }
  }

  private func terminalEffortPill(
    context: TerminalConfigurationContext
  ) -> some View {
    let current = context.effortBinding.wrappedValue
    let valueText = current.isEmpty ? "Default" : current.capitalized
    let label = "Effort \(valueText)"
    let defaultEffort = WorkspaceWindowView.defaultEffortLevel(from: context.effortValues)
    let state: AgentsConfigPillState = current == defaultEffort ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: valueText,
      state: state,
      accessibilityLabel: "Effort"
    ) {
      ForEach(context.effortValues, id: \.self) { level in
        Button(level.capitalized) {
          context.effortBinding.wrappedValue = level
        }
      }
    }
  }

  private var terminalRolePill: some View {
    @Bindable var formModel = viewModel
    let role = formModel.selectedRole
    let label = "Role: \(role.title)"
    let state: AgentsConfigPillState = role == .worker ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: role.title,
      state: state,
      accessibilityLabel: "Role in session"
    ) {
      ForEach(SessionRole.allCases, id: \.self) { option in
        Button(option.title) {
          formModel.selectedRole = option
        }
      }
    }
  }

  private var terminalFallbackRolePill: some View {
    @Bindable var formModel = viewModel
    let role = formModel.selectedAcpFallbackRole
    let label = "Fallback: \(role.title)"
    let state: AgentsConfigPillState = role == .worker ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: role.title,
      state: state,
      accessibilityLabel: "Fallback role"
    ) {
      ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { option in
        Button(option.title) {
          formModel.selectedAcpFallbackRole = option
        }
      }
    }
  }

  private var terminalPersonaPill: some View {
    @Bindable var formModel = viewModel
    let selected = formModel.selectedPersona
    let personaName: String? =
      selected.flatMap { id in
        viewModel.availablePersonas.first(where: { $0.identifier == id })?.name
      }
    let label = personaName ?? "Persona"
    let state: AgentsConfigPillState = personaName == nil ? .additive : .set
    return AgentsConfigPill(
      label: label,
      value: personaName ?? "None",
      state: state,
      accessibilityLabel: "Persona"
    ) {
      Button("None") {
        formModel.selectedPersonaID = ""
      }
      ForEach(viewModel.availablePersonas, id: \.identifier) { persona in
        Button(persona.name) {
          formModel.selectedPersonaID = persona.identifier
        }
      }
    }
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
