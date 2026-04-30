import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
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
    if case .acp = choice.id {
      return option.projectAccessGuidanceText
    }
    return nil
  }

  func providerStatusTint(for option: AgentCapabilityOption) -> Color {
    option.availabilityState.tint
  }

  func transportChoiceSummary(for choice: AgentCapabilityTransportChoice) -> String {
    if choice.id.isAcp {
      return "Starts with project access available."
    }
    return "Opens in Terminal."
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
        personaMenu
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        roleMenu
        personaMenu
      }
    }
  }

  func terminalConfigurationHeader(
    option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(option.title)
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        Text(transportSummary(for: option, choice: choice))
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      AgentsCreateProviderStatusBadge(
        title: option.statusText,
        tint: providerStatusTint(for: option)
      )
    }
  }

  @ViewBuilder
  func terminalTransportChoicesSection(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    if option.transportChoices.count > 1 {
      AgentsCreateFieldBlock(
        title: "Launch with",
        help:
          "Choose whether this provider opens in a terminal first "
          + "or starts with project access when available."
      ) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
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

          Text(transportChoiceSummary(for: context.choice))
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
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
        variant: .bordered,
        accessibilityIdentifier: installButtonID,
        fillsWidth: false
      ) {
        HarnessMonitorClipboard.copy(installHintText(for: option))
      }
      .help(installHintText(for: option))
      .accessibilityHint(option.installAccessibilityHint ?? "")
    }

    if option.doctorProbeText != nil {
      AgentsCreateDiagnosticsDisclosure(option: option)
        .id(option.id)
    }
  }

  func terminalModelField(context: TerminalConfigurationContext) -> some View {
    AgentsCreateFieldBlock(
      title: "Model",
      help: "Choose the default model for the selected provider."
    ) {
      Picker("Model", selection: context.modelBinding) {
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
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsModelPicker)

      if context.modelBinding.wrappedValue == RuntimeCustomModel.tag {
        TextField("Provider-specific model id", text: context.customModelBinding)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCustomModelField)
      }
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
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentsEffortPicker)
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
      .map { Self.effortValues(catalog: $0, selectedModelId: modelBinding.wrappedValue) }
      ?? Self.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedTerminalEffortByRuntime[selectedRuntime],
          effortValues.contains(current)
        else {
          return Self.defaultEffortLevel(from: effortValues)
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
