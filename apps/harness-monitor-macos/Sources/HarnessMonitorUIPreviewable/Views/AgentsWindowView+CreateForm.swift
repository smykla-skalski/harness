import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var createPane: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        createPaneHeader
        createModeCard
        createPaneBanners

        switch viewModel.createMode {
        case .terminal:
          terminalCreateContent
        case .codex:
          codexCreateContent
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: createPaneContentWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiLaunchPane)
  }

  private var createPaneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("New agent")
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(createPaneDescription)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: 620, alignment: .leading)
    }
  }

  private var createModeCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      AgentsCreateFieldBlock(
        title: "Mode",
        help: "Choose the launch flow for this window."
      ) {
        Picker("Mode", selection: $formModel.createMode) {
          ForEach(AgentTuiCreateMode.allCases) { mode in
            Text(mode.title)
              .tag(mode)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.agentTuiCreateModePicker,
                  option: mode.title
                )
              )
          }
        }
        .pickerStyle(.segmented)
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiCreateModePicker)
      }
    }
  }

  @ViewBuilder var createPaneBanners: some View {
    if viewModel.createMode == .terminal && displayState.agentTuiUnavailable {
      agentTuiUnavailableBanner
    }
    if viewModel.createMode == .codex && displayState.codexUnavailable {
      codexUnavailableBanner
    }
  }

  private var createPaneContentWidth: CGFloat {
    viewModel.createMode == .terminal ? 1_040 : 760
  }

  private var usesSplitCreateLayout: Bool {
    (viewModel.lastDetailColumnSize?.width ?? createPaneContentWidth) >= 700
  }

  @ViewBuilder private var terminalCreateContent: some View {
    if usesSplitCreateLayout {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
        terminalProviderCard
          .frame(maxWidth: 280, alignment: .leading)
        terminalConfigurationColumn
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        terminalProviderCard
        terminalConfigurationColumn
      }
    }
  }

  private var terminalProviderCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Provider",
          description: "Pick the runtime you want to launch first. Transport details stay focused on the selected provider."
        )

        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          ForEach(agentCapabilityOptions) { option in
            AgentsCreateProviderRow(
              option: option,
              selection: $formModel.selectedLaunchSelection
            )
          }
        }
        .onChange(of: formModel.selectedLaunchSelection, initial: true) { _, newValue in
          formModel.runtime = newValue.preferredRuntime
        }
        .onChange(of: agentCapabilityOptions, initial: true) { _, options in
          let normalizedSelection = Self.normalizedLaunchSelection(
            options: options,
            selection: formModel.selectedLaunchSelection,
            fallbackRuntime: formModel.runtime
          )
          if normalizedSelection != formModel.selectedLaunchSelection {
            formModel.selectedLaunchSelection = normalizedSelection
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRuntimePicker)
      }
    }
  }

  @ViewBuilder private var terminalConfigurationColumn: some View {
    if let option = selectedCapabilityOption {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        terminalConfigurationCard(option: option)
        terminalDetailsCard
        terminalSizeCard
        terminalLaunchCard
      }
    } else {
      AgentsCreateSectionCard {
        AgentsCreateSectionHeading(
          title: "No provider available",
          description: "A provider must be available before Harness Monitor can start a terminal-backed agent."
        )
      }
    }
  }

  private func terminalConfigurationCard(option: AgentCapabilityOption) -> some View {
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
    let catalogModels = catalog?.models ?? []
    let effortValues =
      catalog
      .map {
        AgentsWindowView.effortValues(catalog: $0, selectedModelId: modelBinding.wrappedValue)
      } ?? AgentsWindowView.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedTerminalEffortByRuntime[selectedRuntime],
          effortValues.contains(current)
        else { return AgentsWindowView.defaultEffortLevel(from: effortValues) }
        return current
      },
      set: { formModel.selectedTerminalEffortByRuntime[selectedRuntime] = $0 }
    )

    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Configuration",
          description: "Tune how \(option.title) launches from the current session."
        )

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

        if option.transportChoices.count > 1 {
          AgentsCreateFieldBlock(
            title: "Launch with",
            help: "Choose whether this provider opens in a terminal first or starts with filesystem tools when available."
          ) {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
              HStack(spacing: HarnessMonitorTheme.spacingSM) {
                ForEach(option.transportChoices) { transportChoice in
                  AgentsCreateTransportChoiceButton(
                    providerTitle: option.title,
                    optionID: option.id,
                    choice: transportChoice,
                    selection: $formModel.selectedLaunchSelection,
                    isSelected: normalizedSelection == transportChoice.id,
                    isEnabled: option.isEnabled(transportChoice),
                    unavailableReason: unavailableReason(for: option, choice: transportChoice)
                  )
                }
              }

              Text(transportChoiceSummary(for: choice))
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }

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
          HarnessMonitorActionButton(
            title: option.installActionTitle,
            tint: .orange,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentCapabilityInstallButton(
              option.id
            )
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

        AgentsCreateFieldBlock(
          title: "Model",
          help: "Choose the default model for the selected provider."
        ) {
          Picker("Model", selection: modelBinding) {
            ForEach(catalogModels) { model in
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

          if modelBinding.wrappedValue == RuntimeCustomModel.tag {
            TextField("Provider-specific model id", text: customModelBinding)
              .harnessNativeFormControl()
              .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCustomModelField)
          }
        }

        if !effortValues.isEmpty {
          AgentsCreateFieldBlock(
            title: "Effort",
            help: "Reasoning effort only appears for models that expose it."
          ) {
            Picker("Effort", selection: effortBinding) {
              ForEach(Array(effortValues.enumerated()), id: \.offset) { _, level in
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
    }
  }

  private var roleMenu: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateFieldBlock(
      title: "Role",
      help: "Choose how the new agent should participate in the session."
    ) {
      Picker("Role", selection: $formModel.selectedRole) {
        ForEach(SessionRole.allCases, id: \.self) { role in
          Text(role.title)
            .tag(role)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.agentsRolePicker,
                option: role.title
              )
            )
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsRolePicker)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var personaMenu: some View {
    AgentsCreateFieldBlock(
      title: "Persona",
      help: "Apply a persona only when you want a consistent behavior template."
    ) {
      Picker(
        "Persona",
        selection: Binding(
          get: { viewModel.selectedPersona ?? "" },
          set: { viewModel.selectedPersona = $0.isEmpty ? nil : $0 }
        )
      ) {
        Text("None")
          .tag("")
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.agentTuiPersonaPicker,
              option: "None"
            )
          )
        ForEach(viewModel.availablePersonas, id: \.identifier) { persona in
          Text(persona.name)
            .tag(persona.identifier)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.agentTuiPersonaCard(persona.identifier)
            )
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPersonaPicker)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var terminalDetailsCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Details",
          description: "Optional metadata and startup input for the first launch."
        )

        AgentsCreateFieldBlock(
          title: "Display name",
          help: "Optional. Leave blank to keep the default provider title."
        ) {
          TextField("Optional display name", text: $formModel.name)
            .harnessNativeFormControl()
            .focused(focusedFieldBinding, equals: .name)
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNameField)
        }

        AgentsCreateFieldBlock(
          title: "Initial prompt",
          help: "Optional. Send the first prompt automatically after the terminal opens."
        ) {
          multilineEditor(
            placeholder: "Optional first prompt to submit inside the terminal agent",
            text: $formModel.prompt,
            field: .prompt,
            minHeight: 84,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiPromptField
          )
        }

        AgentsCreateFieldBlock(
          title: "Project directory",
          help: "Optional. Override the project folder for this launch only."
        ) {
          TextField("Optional project directory override", text: $formModel.projectDir)
            .harnessNativeFormControl()
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiProjectDirField)
        }

        AgentsCreateFieldBlock(
          title: "Command override",
          help: "Optional. One argument per line. The first line is the executable."
        ) {
          multilineEditor(
            placeholder:
              "Optional argv override (one argument per line; first line is the executable)",
            text: $formModel.argvOverride,
            field: .argv,
            minHeight: 100,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiArgvField
          )
        }
      }
    }
  }

  private var terminalSizeCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Terminal size",
          description: "Adjust the starting viewport only when the default size does not fit your workflow."
        )

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
            AgentsCreateFieldBlock(title: "Rows") {
              Stepper(
                "Rows \(formModel.rows)",
                value: $formModel.rows,
                in: TerminalViewportSizing.rowRange
              )
              .harnessNativeFormControl()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentsCreateFieldBlock(title: "Columns") {
              Stepper(
                "Cols \(formModel.cols)",
                value: $formModel.cols,
                in: TerminalViewportSizing.colRange,
                step: 10
              )
              .harnessNativeFormControl()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }

          VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
            AgentsCreateFieldBlock(title: "Rows") {
              Stepper(
                "Rows \(formModel.rows)",
                value: $formModel.rows,
                in: TerminalViewportSizing.rowRange
              )
              .harnessNativeFormControl()
            }
            AgentsCreateFieldBlock(title: "Columns") {
              Stepper(
                "Cols \(formModel.cols)",
                value: $formModel.cols,
                in: TerminalViewportSizing.colRange,
                step: 10
              )
              .harnessNativeFormControl()
            }
          }
        }
      }
    }
  }

  private var terminalLaunchCard: some View {
    AgentsCreateSectionCard {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Ready to launch")
            .scaledFont(.headline)
          Text("Start \(selectedAgentLaunchTitle) with the selected provider and configuration.")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingLG)
        HarnessMonitorActionButton(
          title: "Start \(selectedAgentLaunchTitle)",
          variant: .prominent,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiStartButton,
          fillsWidth: false
        ) {
          startTui()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canStartTerminal)
      }
    }
  }

  private var codexCreateContent: some View {
    Group {
      if usesSplitCreateLayout {
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
          codexPromptCard
            .frame(maxWidth: 360, alignment: .leading)
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
            codexConfigurationCard
            codexLaunchCard
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
          codexPromptCard
          codexConfigurationCard
          codexLaunchCard
        }
      }
    }
  }

  private var codexPromptCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Prompt",
          description: "Describe the work clearly so Codex can start with the right context."
        )

        multilineEditor(
          placeholder: "Ask Codex to investigate or patch this session",
          text: $formModel.codexPrompt,
          field: .prompt,
          minHeight: 140,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexPromptField
        )
      }
    }
  }

  private var codexConfigurationCard: some View {
    @Bindable var formModel = viewModel
    let catalog = codexCatalog(formModel)
    let modelBinding = Binding<String>(
      get: { formModel.selectedCodexModel ?? catalog?.default ?? RuntimeCustomModel.tag },
      set: { formModel.selectedCodexModel = $0 }
    )
    let customModelBinding = Binding<String>(
      get: { formModel.customCodexModel ?? "" },
      set: { formModel.customCodexModel = $0 }
    )
    let catalogModels = catalog?.models ?? []
    let effortValues =
      catalog
      .map {
        AgentsWindowView.effortValues(catalog: $0, selectedModelId: modelBinding.wrappedValue)
      } ?? AgentsWindowView.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedCodexEffort,
          effortValues.contains(current)
        else { return AgentsWindowView.defaultEffortLevel(from: effortValues) }
        return current
      },
      set: { formModel.selectedCodexEffort = $0 }
    )

    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Configuration",
          description: "Choose the Codex mode, model, and reasoning level for this run."
        )

        AgentsCreateFieldBlock(
          title: "Run mode",
          help: "Report is best for investigation, workspace write for direct patches, and approval for gated edits."
        ) {
          Picker("Run mode", selection: $formModel.codexMode) {
            ForEach(CodexRunMode.allCases) { mode in
              Text(mode.title)
                .tag(mode)
                .accessibilityIdentifier(
                  HarnessMonitorAccessibility.segmentedOption(
                    HarnessMonitorAccessibility.agentsCodexModePicker,
                    option: mode.title
                  )
                )
            }
          }
          .pickerStyle(.segmented)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexModePicker)
        }

        AgentsCreateFieldBlock(
          title: "Model",
          help: "Pick the default Codex model for this thread."
        ) {
          Picker("Model", selection: modelBinding) {
            ForEach(catalogModels) { model in
              Text(model.displayName)
                .tag(model.id)
                .accessibilityIdentifier(
                  HarnessMonitorAccessibility.segmentedOption(
                    HarnessMonitorAccessibility.agentsCodexModelPicker,
                    option: model.displayName
                  )
                )
            }
            Text("Custom...")
              .tag(RuntimeCustomModel.tag)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.agentsCodexModelPicker,
                  option: "Custom"
                )
              )
          }
          .pickerStyle(.menu)
          .harnessNativeFormControl()
          .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsCodexModelPicker).frame")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexModelPicker)

          if modelBinding.wrappedValue == RuntimeCustomModel.tag {
            TextField("Provider-specific model id", text: customModelBinding)
              .harnessNativeFormControl()
              .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexCustomModelField)
          }
        }

        if !effortValues.isEmpty {
          AgentsCreateFieldBlock(
            title: "Effort",
            help: "Reasoning effort only appears for models that expose it."
          ) {
            Picker("Effort", selection: effortBinding) {
              ForEach(Array(effortValues.enumerated()), id: \.offset) { _, level in
                Text(level.capitalized)
                  .tag(level)
                  .accessibilityIdentifier(
                    HarnessMonitorAccessibility.segmentedOption(
                      HarnessMonitorAccessibility.agentsCodexEffortPicker,
                      option: level
                    )
                  )
              }
            }
            .pickerStyle(.segmented)
            .harnessNativeFormControl()
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexEffortPicker)
          }
        }
      }
    }
  }

  private var codexLaunchCard: some View {
    AgentsCreateSectionCard {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Ready to launch")
            .scaledFont(.headline)
          Text("Start a Codex thread from this window with the selected mode and model.")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingLG)
        HarnessMonitorActionButton(
          title: "Start Codex",
          variant: .prominent,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexSubmitButton,
          fillsWidth: false
        ) {
          startTui()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canStartCodex)
      }
    }
  }

  private var selectedCapabilityOption: AgentCapabilityOption? {
    agentCapabilityOptions.first { option in
      option.transportChoices.contains { $0.id == viewModel.selectedLaunchSelection }
    } ?? agentCapabilityOptions.first
  }

  private func installHintText(for option: AgentCapabilityOption) -> String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  private func unavailableReason(
    for option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String? {
    if case .acp = choice.id, option.sandboxed, !option.acpHostBridgeReady {
      return "Filesystem + terminal tools require the ACP host bridge while the daemon runs sandboxed."
    }
    if option.showsInstallCTA {
      return "Install \(option.title) CLI to enable filesystem + terminal tools."
    }
    return option.installHint
  }

  private func providerStatusTint(for option: AgentCapabilityOption) -> Color {
    if option.showsInstallCTA {
      return HarnessMonitorTheme.caution
    }
    if option.transportChoices.contains(where: { $0.id.isAcp }) {
      return option.isEnabled ? HarnessMonitorTheme.success : HarnessMonitorTheme.secondaryInk
    }
    return HarnessMonitorTheme.accent
  }

  private func transportChoiceSummary(for choice: AgentCapabilityTransportChoice) -> String {
    if choice.id.isAcp {
      return "Starts with filesystem + terminal tools."
    }
    return "Starts in a terminal screen."
  }

  private func transportSummary(
    for option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> String {
    if choice.id.isAcp {
      return "Starts with filesystem + terminal tools for richer project access."
    }

    if let acpChoice = option.acpChoice {
      if option.isEnabled(acpChoice) {
        return "Starts in a terminal screen. Filesystem + terminal tools are also available."
      }
      if option.showsInstallCTA {
        return "Starts in a terminal screen. Install filesystem + terminal tools for richer project access."
      }
      if option.hasPendingAcpProbe {
        return "Starts in a terminal screen while Harness Monitor checks filesystem + terminal tools."
      }
    }

    return "Starts in a terminal screen."
  }
}

private struct AgentsCreateSectionCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(HarnessMonitorTheme.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .fill(HarnessMonitorTheme.ink.opacity(0.035))
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.6), lineWidth: 1)
      }
  }
}

private struct AgentsCreateSectionHeading: View {
  let title: String
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
      Text(description)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct AgentsCreateFieldBlock<Content: View>: View {
  let title: String
  let help: String?
  private let content: Content

  init(
    title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      content

      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct AgentsCreateProviderRow: View {
  let option: AgentCapabilityOption
  @Binding var selection: AgentLaunchSelection

  private var normalizedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: selection)
  }

  private var currentChoice: AgentCapabilityTransportChoice {
    option.transportChoice(for: normalizedSelection)
  }

  private var isSelected: Bool {
    option.transportChoices.contains(where: { $0.id == selection }) || selection == normalizedSelection
  }

  private var capabilitySummary: String {
    let labels = option.acpChoice?.capabilityLabels ?? currentChoice.capabilityLabels
    return labels.joined(separator: ", ")
  }

  private var accessibilityRowLabel: String {
    "\(option.accessibilityLabel), capabilities: \(capabilitySummary)"
  }

  private var subtitle: String {
    if currentChoice.id.isAcp {
      return "Starts with filesystem + terminal tools."
    }
    if let acpChoice = option.acpChoice, option.isEnabled(acpChoice) {
      return "Starts in a terminal screen. Filesystem + terminal tools are also available."
    }
    if option.showsInstallCTA {
      return "Starts in a terminal screen. Install tools for richer project access."
    }
    return "Starts in a terminal screen."
  }

  private var statusTint: Color {
    if option.showsInstallCTA {
      return HarnessMonitorTheme.caution
    }
    if option.transportChoices.contains(where: { $0.id.isAcp }) {
      return option.isEnabled ? HarnessMonitorTheme.success : HarnessMonitorTheme.secondaryInk
    }
    return HarnessMonitorTheme.accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        selection = normalizedSelection
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              Text(option.title)
                .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              Text(subtitle)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HarnessMonitorTheme.spacingSM)

            AgentsCreateProviderStatusBadge(title: option.statusText, tint: statusTint)
          }

          Text(capabilitySummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(2)
        }
        .padding(HarnessMonitorTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.1) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .stroke(
              HarnessMonitorTheme.accent.opacity(0.45),
              lineWidth: 1.5
            )
            .opacity(isSelected ? 1 : 0)
        }
      }
      .harnessInteractiveCardButtonStyle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
        tint: isSelected ? HarnessMonitorTheme.accent : nil,
        extraHoverHint: isSelected
      )
      .accessibilityLabel(option.title)
      .accessibilityHint("Select provider")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.segmentedOption(
          HarnessMonitorAccessibility.agentTuiRuntimePicker,
          option: option.title
        )
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityRow(option.id))
  }
}

private struct AgentsCreateProviderStatusBadge: View {
  let title: String
  let tint: Color

  var body: some View {
    Text(title)
      .scaledFont(.caption.weight(.semibold))
      .harnessPillPadding()
      .harnessContentPill(tint: tint)
  }
}

private struct AgentsCreateTransportChoiceButton: View {
  let providerTitle: String
  let optionID: String
  let choice: AgentCapabilityTransportChoice
  @Binding var selection: AgentLaunchSelection
  let isSelected: Bool
  let isEnabled: Bool
  let unavailableReason: String?

  private var shortTitle: String {
    choice.id.isAcp ? "Tools" : "Terminal"
  }

  var body: some View {
    Button {
      selection = choice.id
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        Text(shortTitle)
      }
      .frame(maxWidth: .infinity)
    }
    .harnessActionButtonStyle(
      variant: isSelected ? .prominent : .bordered,
      tint: isSelected ? nil : .secondary
    )
    .disabled(!isEnabled)
    .accessibilityLabel("\(providerTitle), \(choice.title)")
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityHint(isEnabled ? "" : (unavailableReason ?? "Unavailable"))
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentCapabilityTransportButton(
        optionID,
        transportID: choice.id.accessibilityIDComponent
      )
    )
  }
}

private struct AgentsCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Button(isExpanded ? "Hide diagnostics" : "Show diagnostics") {
        isExpanded.toggle()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .accessibilityLabel(
        "\(isExpanded ? "Hide" : "Show") diagnostics for \(option.title)"
      )
      .accessibilityHint(option.statusText)
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id))

      if isExpanded, let doctorProbeText = option.doctorProbeText {
        Text(doctorProbeText)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityProbe(option.id))
      }
    }
  }
}
