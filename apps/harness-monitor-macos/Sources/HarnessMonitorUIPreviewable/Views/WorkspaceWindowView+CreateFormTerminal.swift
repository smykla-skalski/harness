import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
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
          description: "Choose the provider that should open when this agent starts."
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
          let normalizedSelection = WorkspaceWindowView.normalizedLaunchSelection(
            options: options,
            selection: formModel.selectedLaunchSelection,
            fallbackRuntime: formModel.runtime
          )
          if normalizedSelection != formModel.selectedLaunchSelection {
            formModel.selectedLaunchSelection = normalizedSelection
          }
        }
        .harnessMCPList(
          HarnessMonitorAccessibility.agentTuiRuntimePicker,
          label: "Provider"
        )
      }
    }
  }

  @ViewBuilder private var terminalConfigurationColumn: some View {
    if let option = selectedCapabilityOption {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        terminalConfigurationCard(option: option)
        terminalLaunchCard
        terminalDetailsCard
        terminalSizeCard
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
          description: "Choose how \(option.title) joins this session and which defaults it uses."
        )
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
      title: "Role in session",
      help: "Choose how this agent joins the current session."
    ) {
      Picker("Role", selection: $formModel.selectedRole) {
        ForEach(SessionRole.allCases, id: \.self) { role in
          Text(role.title)
            .tag(role)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceRolePicker,
                option: role.title
              )
            )
            .harnessMCPMenuItem(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceRolePicker,
                option: role.title
              ),
              label: role.title,
              pressAction: { formModel.selectedRole = role }
            )
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .harnessMCPButton(HarnessMonitorAccessibility.workspaceRolePicker, label: "Role")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var personaMenu: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateFieldBlock(
      title: "Persona (optional)",
      help: "Apply one only when you want a consistent behavior template."
    ) {
      Picker("Persona", selection: $formModel.selectedPersonaID) {
        Text("None")
          .tag("")
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspacePersonaPicker,
              option: "None"
            )
          )
          .harnessMCPMenuItem(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.workspacePersonaPicker,
              option: "None"
            ),
            label: "None",
            pressAction: { formModel.selectedPersonaID = "" }
          )
        ForEach(viewModel.availablePersonas, id: \.identifier) { persona in
          Text(persona.name)
            .tag(persona.identifier)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.workspacePersonaCard(persona.identifier)
            )
            .harnessMCPMenuItem(
              HarnessMonitorAccessibility.workspacePersonaCard(persona.identifier),
              label: persona.name,
              pressAction: { formModel.selectedPersonaID = persona.identifier }
            )
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .harnessMCPButton(
        HarnessMonitorAccessibility.workspacePersonaPicker,
        label: "Persona"
      )

      Text(selectedPersonaStateText)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var acpFallbackRoleMenu: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateFieldBlock(
      title: "If leader already exists",
      help: "Choose how project access joins when another leader is active."
    ) {
      Picker("Fallback role", selection: $formModel.selectedAcpFallbackRole) {
        ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { role in
          Text(role.title)
            .tag(role)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceFallbackRolePicker,
                option: role.title
              )
            )
            .harnessMCPMenuItem(
              HarnessMonitorAccessibility.segmentedOption(
                HarnessMonitorAccessibility.workspaceFallbackRolePicker,
                option: role.title
              ),
              label: role.title,
              pressAction: { formModel.selectedAcpFallbackRole = role }
            )
        }
      }
      .pickerStyle(.menu)
      .harnessNativeFormControl()
      .harnessMCPButton(
        HarnessMonitorAccessibility.workspaceFallbackRolePicker,
        label: "Fallback role"
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var terminalDetailsCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(
          title: "Details",
          description: "Name this launch or seed the first message before the agent opens."
        )

        AgentsCreateFieldBlock(
          title: "Display name",
          help: nil
        ) {
          TextField("Optional display name", text: $formModel.name)
            .harnessNativeFormControl()
            .focused(focusedFieldBinding, equals: .name)
            .harnessMCPTextField(
              HarnessMonitorAccessibility.agentTuiNameField,
              label: "Display name",
              value: formModel.name
            )
        }

        AgentsCreateFieldBlock(
          title: "Initial prompt",
          help: nil
        ) {
          multilineEditor(
            placeholder: "Optional first prompt to submit inside the terminal agent",
            text: $formModel.prompt,
            field: .prompt,
            minHeight: 84,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiPromptField
          )
        }

        DisclosureGroup {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
            AgentsCreateFieldBlock(
              title: "Project directory override",
              help: nil
            ) {
              TextField("Optional project directory override", text: $formModel.projectDir)
                .harnessNativeFormControl()
                .harnessMCPTextField(
                  HarnessMonitorAccessibility.agentTuiProjectDirField,
                  label: "Project directory override",
                  value: formModel.projectDir
                )
            }

            AgentsCreateFieldBlock(
              title: "Command override",
              help: "One argument per line. The first line is the executable."
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
          .padding(.top, HarnessMonitorTheme.spacingSM)
        } label: {
          Text("Advanced overrides")
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
          Text(terminalLaunchCalloutText)
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
          startAction()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canStartTerminal)
      }
    }
  }

  private var terminalLaunchCalloutText: String {
    var message = "Launches as \(viewModel.selectedRole.title)."

    if showsAcpFallbackRoleMenu {
      message +=
        " If a leader is already active, it joins as \(viewModel.selectedAcpFallbackRole.title)."
    }

    return message
  }

}
