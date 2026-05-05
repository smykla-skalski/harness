import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  var codexCreateContent: some View {
    createPaneColumns(leadingMaxWidth: 360) {
      codexPromptCard
    } trailing: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        codexConfigurationCard
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var codexRuntimeCatalog: RuntimeModelCatalog? {
    viewModel.availableRuntimeModels.first { $0.runtime == "codex" }
  }

  private var codexPromptCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(title: "Prompt")

        multilineEditor(
          placeholder: "Ask Codex to investigate or patch this session",
          text: $formModel.codexPrompt,
          field: .prompt,
          minHeight: 140,
          accessibilityIdentifier: HarnessMonitorAccessibility.workspaceCodexPromptField
        )
      }
    }
  }

  private var codexConfigurationCard: some View {
    @Bindable var formModel = viewModel
    let modelBinding = Binding<String>(
      get: {
        formModel.selectedCodexModel
          ?? codexRuntimeCatalog?.default
          ?? RuntimeCustomModel.tag
      },
      set: { formModel.selectedCodexModel = $0 }
    )
    let customModelBinding = Binding<String>(
      get: { formModel.customCodexModel ?? "" },
      set: { formModel.customCodexModel = $0 }
    )
    let catalogModels = codexRuntimeCatalog?.models ?? []
    let effortValues =
      codexRuntimeCatalog
      .map {
        WorkspaceWindowView.effortValues(catalog: $0, selectedModelId: modelBinding.wrappedValue)
      } ?? WorkspaceWindowView.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedCodexEffort,
          effortValues.contains(current)
        else { return WorkspaceWindowView.defaultEffortLevel(from: effortValues) }
        return current
      },
      set: { formModel.selectedCodexEffort = $0 }
    )

    return AgentsCreateSectionCard {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          codexModePicker(formModel: formModel)
          codexModelPicker(
            modelBinding: modelBinding,
            customModelBinding: customModelBinding,
            catalogModels: catalogModels
          )
          codexEffortPicker(effortValues: effortValues, effortBinding: effortBinding)
        }
        .padding(.top, HarnessMonitorTheme.spacingSM)
      } label: {
        Text("Configure")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
      }
    }
  }

  private func codexModePicker(formModel: ViewModel) -> some View {
    @Bindable var formModel = formModel
    return AgentsCreateFieldBlock(title: "Run mode") {
      Picker("Run mode", selection: $formModel.codexMode) {
        ForEach(CodexRunMode.allCases) { mode in
          Text(mode.title)
            .tag(mode)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceCodexModePicker,
                option: mode.title
              )
            )
            .harnessMCPButton(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceCodexModePicker,
                option: mode.title
              ),
              label: mode.title,
              pressAction: { formModel.codexMode = mode }
            )
        }
      }
      .pickerStyle(.segmented)
      .harnessNativeFormControl()
      .harnessMCPButton(
        HarnessMonitorAccessibility.workspaceCodexModePicker,
        label: "Run mode"
      )
    }
  }

  private func codexModelPicker(
    modelBinding: Binding<String>,
    customModelBinding: Binding<String>,
    catalogModels: [RuntimeModel]
  ) -> some View {
    AgentsCreateFieldBlock(title: "Model") {
      Picker("Model", selection: modelBinding) {
        ForEach(catalogModels) { model in
          Text(model.displayName)
            .tag(model.id)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceCodexModelPicker,
                option: model.displayName
              )
            )
            .harnessMCPMenuItem(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceCodexModelPicker,
                option: model.displayName
              ),
              label: model.displayName,
              pressAction: { modelBinding.wrappedValue = model.id }
            )
        }
        Text("Custom...")
          .tag(RuntimeCustomModel.tag)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspaceCodexModelPicker,
              option: "Custom"
            )
          )
          .harnessMCPMenuItem(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspaceCodexModelPicker,
              option: "Custom"
            ),
            label: "Custom",
            pressAction: { modelBinding.wrappedValue = RuntimeCustomModel.tag }
          )
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.workspaceCodexModelPicker).frame")
      .harnessMCPButton(
        HarnessMonitorAccessibility.workspaceCodexModelPicker,
        label: "Model"
      )

      if modelBinding.wrappedValue == RuntimeCustomModel.tag {
        TextField("Provider-specific model id", text: customModelBinding)
          .harnessNativeTextField()
          .harnessMCPTextField(
            HarnessMonitorAccessibility.workspaceCodexCustomModelField,
            label: "Provider-specific model id",
            value: customModelBinding.wrappedValue
          )
      }
    }
  }

  @ViewBuilder
  private func codexEffortPicker(
    effortValues: [String],
    effortBinding: Binding<String>
  ) -> some View {
    if !effortValues.isEmpty {
      AgentsCreateFieldBlock(title: "Effort") {
        Picker("Effort", selection: effortBinding) {
          ForEach(Array(effortValues.enumerated()), id: \.offset) { _, level in
            Text(level.capitalized)
              .tag(level)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.workspaceCodexEffortPicker,
                  option: level
                )
              )
              .harnessMCPButton(
                HarnessMonitorAccessibility.segmentedOption(
                  HarnessMonitorAccessibility.workspaceCodexEffortPicker,
                  option: level
                ),
                label: level.capitalized,
                pressAction: { effortBinding.wrappedValue = level }
              )
          }
        }
        .pickerStyle(.segmented)
        .harnessNativeFormControl()
        .harnessMCPButton(
          HarnessMonitorAccessibility.workspaceCodexEffortPicker,
          label: "Effort"
        )
      }
    }
  }

  var resolvedCreateSessionID: String? {
    let selectionSessionID = WorkspaceWindowView.normalizedCreateSessionAnchor(
      viewModel.selection.sessionID
    )
    let createSessionID = WorkspaceWindowView.normalizedCreateSessionAnchor(
      viewModel.createSessionID
    )
    let selectedSessionID = WorkspaceWindowView.normalizedCreateSessionAnchor(
      store.selectedSessionID
    )

    if let selectionSessionID,
      store.sessionIndex.sessionSummary(for: selectionSessionID) != nil
    {
      return selectionSessionID
    }
    if let createSessionID,
      store.sessionIndex.sessionSummary(for: createSessionID) != nil
    {
      return createSessionID
    }
    return selectedSessionID ?? createSessionID ?? selectionSessionID
  }

  var createPaneSessionActionUnavailableNote: String? {
    store.sessionActionUnavailableMessage(sessionID: resolvedCreateSessionID)
  }

  private var trimmedCodexPrompt: String {
    viewModel.codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var canStartCodex: Bool {
    createPaneSessionActionUnavailableNote == nil
      && !viewModel.isSubmitting
      && !trimmedCodexPrompt.isEmpty
  }

  var terminalLaunchSummaryChipText: String {
    guard let option = selectedCapabilityOption else {
      return "Choose a provider"
    }
    let normalizedSelection = option.normalizedSelection(for: viewModel.selectedLaunchSelection)
    let choice = option.transportChoice(for: normalizedSelection)
    let transport = choice.id.isAcp ? "ACP" : "Terminal"
    let role = viewModel.selectedRole.title
    var fragments = [option.title, transport, role]
    let runtime = normalizedSelection.preferredRuntime
    if let modelID = viewModel.selectedTerminalModelByRuntime[runtime] {
      let catalog = viewModel.availableRuntimeModels.first { $0.runtime == runtime.rawValue }
      let modelName =
        catalog?.models.first { $0.id == modelID }?.displayName ?? modelID
      fragments.append(modelName)
    }
    return fragments.joined(separator: " · ")
  }

  var codexLaunchSummaryChipText: String {
    var fragments: [String] = ["Codex", viewModel.codexMode.title]
    if let modelID = viewModel.selectedCodexModel,
      let catalog = codexRuntimeCatalog
    {
      let modelName =
        catalog.models.first { $0.id == modelID }?.displayName ?? modelID
      fragments.append(modelName)
    }
    if let effort = viewModel.selectedCodexEffort {
      fragments.append("Effort \(effort.capitalized)")
    }
    return fragments.joined(separator: " · ")
  }
}
