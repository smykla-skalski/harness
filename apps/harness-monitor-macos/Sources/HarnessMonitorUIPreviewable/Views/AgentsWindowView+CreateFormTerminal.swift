import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  @ViewBuilder var terminalCreateContent: some View {
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
          description:
            "Pick the runtime you want to launch first. "
            + "Transport details stay focused on the selected provider."
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
          description:
            "A provider must be available before Harness Monitor can start "
            + "a terminal-backed agent."
        )
      }
    }
  }

  private func terminalConfigurationCard(option: AgentCapabilityOption) -> some View {
    let context = terminalConfigurationContext(for: option)

    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Configuration",
          description: "Tune how \(option.title) launches from the current session."
        )
        terminalConfigurationHeader(option: option, choice: context.choice)
        terminalTransportChoicesSection(option: option, context: context)
        terminalTransportNotice(option: option, choice: context.choice)
        terminalModelField(context: context)
        terminalEffortField(context: context)
        roleAndPersonaSection
      }
    }
  }

  var roleMenu: some View {
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

  var personaMenu: some View {
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
          description:
            "Adjust the starting viewport only when the default size "
            + "does not fit your workflow."
        )

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
            terminalSizeStepper(
              title: "Rows",
              value: $formModel.rows,
              range: TerminalViewportSizing.rowRange
            )
            terminalSizeStepper(
              title: "Columns",
              value: $formModel.cols,
              range: TerminalViewportSizing.colRange,
              step: 10
            )
          }

          VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
            terminalSizeStepper(
              title: "Rows",
              value: $formModel.rows,
              range: TerminalViewportSizing.rowRange
            )
            terminalSizeStepper(
              title: "Columns",
              value: $formModel.cols,
              range: TerminalViewportSizing.colRange,
              step: 10
            )
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

}
