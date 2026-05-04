import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  var codexCreateContent: some View {
    createPaneColumns(leadingMaxWidth: 360) {
      codexPromptCard
    } trailing: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        codexConfigurationCard
        codexLaunchCard
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
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(title: "Configuration")

        codexModePicker(formModel: formModel)
        codexModelPicker(
          modelBinding: modelBinding,
          customModelBinding: customModelBinding,
          catalogModels: catalogModels
        )
        codexEffortPicker(effortValues: effortValues, effortBinding: effortBinding)
      }
    }
  }

  private func codexModePicker(formModel: ViewModel) -> some View {
    @Bindable var formModel = formModel
    return AgentsCreateFieldBlock(
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
          .harnessNativeFormControl()
          .harnessMCPTextField(
            HarnessMonitorAccessibility.workspaceCodexCustomModelField,
            label: "Provider-specific model id",
            value: customModelBinding.wrappedValue
          )
          .harnessPreservePrimaryContentFocus()
      }
    }
  }

  @ViewBuilder
  private func codexEffortPicker(
    effortValues: [String],
    effortBinding: Binding<String>
  ) -> some View {
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
          accessibilityIdentifier: HarnessMonitorAccessibility.workspaceCodexSubmitButton,
          fillsWidth: false
        ) {
          startAction()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canStartCodex)
      }
    }
  }

  var resolvedCreateSessionID: String? {
    viewModel.selection.sessionID ?? viewModel.createSessionID ?? store.selectedSessionID
  }

  var createPaneSessionActionUnavailableNote: String? {
    store.sessionActionUnavailableMessage(sessionID: resolvedCreateSessionID)
  }

  private var trimmedCodexPrompt: String {
    viewModel.codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canStartCodex: Bool {
    createPaneSessionActionUnavailableNote == nil
      && !viewModel.isSubmitting
      && !trimmedCodexPrompt.isEmpty
  }
}
