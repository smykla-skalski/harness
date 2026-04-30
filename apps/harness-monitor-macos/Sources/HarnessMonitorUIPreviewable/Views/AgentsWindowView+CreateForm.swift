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
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiLaunchPane)
  }

  private var createPaneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(viewModel.createMode.headerTitle)
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
        title: "Create",
        help: "Choose whether this window starts an agent or a Codex run."
      ) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          Picker("Create", selection: $formModel.createMode) {
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

          AgentsCreateSummaryFactsView(facts: createSummaryFacts)
        }
      }
    }
  }

  private var createSummaryFacts: [AgentsCreateSummaryFact] {
    switch viewModel.createMode {
    case .terminal:
      terminalCreateSummaryFacts
    case .codex:
      codexCreateSummaryFacts
    }
  }

  private var terminalCreateSummaryFacts: [AgentsCreateSummaryFact] {
    let facts = [
      AgentsCreateSummaryFact(title: "Provider", value: selectedAgentLaunchTitle),
      AgentsCreateSummaryFact(title: "Starts with", value: selectedTransportSummaryTitle),
    ]

    return facts
  }

  private var codexCreateSummaryFacts: [AgentsCreateSummaryFact] {
    var facts = [
      AgentsCreateSummaryFact(title: "Run mode", value: viewModel.codexMode.title),
      AgentsCreateSummaryFact(title: "Model", value: selectedCodexModelTitle),
    ]

    if let selectedEffort = selectedCodexEffortTitle {
      facts.append(AgentsCreateSummaryFact(title: "Effort", value: selectedEffort))
    }

    return facts
  }

  var selectedTransportSummaryTitle: String {
    guard let option = selectedCapabilityOption else {
      return "Choose a provider"
    }

    let selectedChoice = option.transportChoice(
      for: option.normalizedSelection(for: viewModel.selectedLaunchSelection)
    )
    return selectedChoice.id.isAcp ? "Project Access" : "Terminal"
  }

  private var selectedPersonaName: String? {
    guard let selectedPersona = viewModel.selectedPersona else {
      return nil
    }

    return viewModel.availablePersonas.first { $0.identifier == selectedPersona }?.name
  }

  private var selectedCodexModelTitle: String {
    let catalog = codexCatalog(viewModel)
    let selectedModelID = viewModel.selectedCodexModel ?? catalog?.default ?? RuntimeCustomModel.tag
    if selectedModelID == RuntimeCustomModel.tag {
      return "Custom model"
    }
    return catalog?.models.first { $0.id == selectedModelID }?.displayName ?? selectedModelID
  }

  private var selectedCodexEffortTitle: String? {
    let catalog = codexCatalog(viewModel)
    let selectedModelID = viewModel.selectedCodexModel ?? catalog?.default ?? RuntimeCustomModel.tag
    let availableEffortValues =
      catalog.map { Self.effortValues(catalog: $0, selectedModelId: selectedModelID) }
      ?? Self.allEffortLevels
    guard !availableEffortValues.isEmpty else {
      return nil
    }
    let selectedEffort =
      viewModel.selectedCodexEffort ?? Self.defaultEffortLevel(from: availableEffortValues)
    return selectedEffort.capitalized
  }

  @ViewBuilder var createPaneBanners: some View {
    if viewModel.createMode == .terminal {
      if viewModel.selectedLaunchSelection.isAcp {
        if displayState.acpUnavailable {
          acpUnavailableBanner
        }
      } else if displayState.agentTuiUnavailable {
        agentTuiUnavailableBanner
      }
    }
    if viewModel.createMode == .codex && displayState.codexUnavailable {
      codexUnavailableBanner
    }
  }

  private var createPaneContentWidth: CGFloat {
    viewModel.createMode == .terminal ? 1_040 : 760
  }

  var usesSplitCreateLayout: Bool {
    (viewModel.lastDetailColumnSize?.width ?? createPaneContentWidth) >= 700
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
          help:
            "Report is best for investigation, workspace write for direct patches, "
            + "and approval for gated edits."
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

}
