import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  var createPane: some View {
    Form {
      createPaneBanners
      modeSection
      switch viewModel.createMode {
      case .terminal:
        terminalRuntimeSection
        terminalDetailsSection
        terminalSizeSection
        terminalLaunchSection
      case .codex:
        codexPromptSection
        codexConfigurationSection
        codexLaunchSection
      }
    }
    .harnessNativeFormContainer()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiLaunchPane)
  }

  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      if displayState.hasAgentTuis {
        "Open terminal-backed agents stay pinned in the sidebar so you can launch "
          + "another agent without losing the active viewport."
      } else {
        "Start a terminal-backed agent to inspect the live screen and steer it from Harness Monitor."
      }
    case .codex:
      if displayState.hasCodexRuns {
        "Codex threads stay pinned in the sidebar so you can continue active work without losing context."
      } else {
        "Start a Codex thread to investigate, patch, or route approvals from the same Agents window."
      }
    }
  }

  @ViewBuilder var createPaneBanners: some View {
    if viewModel.createMode == .terminal && displayState.agentTuiUnavailable {
      Section { agentTuiUnavailableBanner }
    }
    if viewModel.createMode == .codex && displayState.codexUnavailable {
      Section { codexUnavailableBanner }
    }
  }

  var modeSection: some View {
    @Bindable var formModel = viewModel
    return Section {
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
    } header: {
      Text("New agent")
    } footer: {
      Text(createPaneDescription)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  var terminalRuntimeSection: some View {
    @Bindable var formModel = viewModel
    let catalog = terminalRuntimeCatalog(formModel)
    let modelBinding = Binding<String>(
      get: {
        formModel.selectedTerminalModelByRuntime[formModel.runtime]
          ?? catalog?.default ?? RuntimeCustomModel.tag
      },
      set: { formModel.selectedTerminalModelByRuntime[formModel.runtime] = $0 }
    )
    let customModelBinding = Binding<String>(
      get: { formModel.customTerminalModelByRuntime[formModel.runtime] ?? "" },
      set: { formModel.customTerminalModelByRuntime[formModel.runtime] = $0 }
    )
    let catalogModels = catalog?.models ?? []
    let effortValues =
      catalog
      .map {
        AgentsWindowView.effortValues(catalog: $0, selectedModelId: modelBinding.wrappedValue)
      } ?? AgentsWindowView.allEffortLevels
    let effortBinding = Binding<String>(
      get: {
        guard let current = formModel.selectedTerminalEffortByRuntime[formModel.runtime],
          effortValues.contains(current)
        else { return AgentsWindowView.defaultEffortLevel(from: effortValues) }
        return current
      },
      set: { formModel.selectedTerminalEffortByRuntime[formModel.runtime] = $0 }
    )
    return Section {
      Picker("Runtime", selection: $formModel.runtime) {
        ForEach(AgentTuiRuntime.allCases) { runtime in
          Text(runtime.title)
            .tag(runtime)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.agentTuiRuntimePicker,
                option: runtime.title
              )
            )
        }
      }
      .pickerStyle(.segmented)
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRuntimePicker)

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

      Picker("Effort", selection: effortBinding) {
        ForEach(effortValues, id: \.self) { level in
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
      .pickerStyle(.segmented)
      .harnessNativeFormControl()
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsRolePicker)

      inlinePersonaPicker
    } header: {
      Text("Runtime")
    }
  }

  var terminalDetailsSection: some View {
    @Bindable var formModel = viewModel
    return Section {
      TextField("Optional display name", text: $formModel.name)
        .harnessNativeFormControl()
        .focused(focusedFieldBinding, equals: .name)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNameField)
      multilineEditor(
        placeholder: "Optional first prompt to submit inside the terminal agent",
        text: $formModel.prompt,
        field: .prompt,
        minHeight: 72,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiPromptField
      )
      TextField("Optional project directory override", text: $formModel.projectDir)
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiProjectDirField)
      multilineEditor(
        placeholder:
          "Optional argv override (one argument per line; first line is the executable)",
        text: $formModel.argvOverride,
        field: .argv,
        minHeight: 88,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiArgvField
      )
    } header: {
      Text("Details")
    }
  }

  var terminalSizeSection: some View {
    @Bindable var formModel = viewModel
    return Section {
      Stepper(
        "Rows \(formModel.rows)",
        value: $formModel.rows,
        in: TerminalViewportSizing.rowRange
      )
      .harnessNativeFormControl()
      Stepper(
        "Cols \(formModel.cols)",
        value: $formModel.cols,
        in: TerminalViewportSizing.colRange,
        step: 10
      )
      .harnessNativeFormControl()
    } header: {
      Text("Terminal size")
    }
  }

  var terminalLaunchSection: some View {
    Section {
      HarnessMonitorActionButton(
        title: "Start \(viewModel.runtime.title)",
        variant: .prominent,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiStartButton,
        fillsWidth: true
      ) {
        startTui()
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!canStartTerminal)
    }
  }

  var codexPromptSection: some View {
    @Bindable var formModel = viewModel
    return Section {
      multilineEditor(
        placeholder: "Ask Codex to investigate or patch this session",
        text: $formModel.codexPrompt,
        field: .prompt,
        minHeight: 120,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexPromptField
      )
    } header: {
      Text("Prompt")
    }
  }

  var codexConfigurationSection: some View {
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
    return Section {
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

      Picker("Effort", selection: effortBinding) {
        ForEach(effortValues, id: \.self) { level in
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
    } header: {
      Text("Codex thread")
    } footer: {
      Text(
        "Use report for investigation, workspace write for direct patches, and approval for gated edits."
      )
      .scaledFont(.footnote)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  var codexLaunchSection: some View {
    Section {
      HarnessMonitorActionButton(
        title: "Start Codex",
        variant: .prominent,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexSubmitButton,
        fillsWidth: true
      ) {
        startTui()
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!canStartCodex)
    }
  }

  var inlinePersonaPicker: some View {
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
}
