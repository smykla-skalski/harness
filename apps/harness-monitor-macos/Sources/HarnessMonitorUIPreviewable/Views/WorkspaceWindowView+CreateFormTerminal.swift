import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  var terminalCreateContent: some View {
    createPaneColumns(leadingMaxWidth: 280) {
      terminalProviderCard
    } trailing: {
      terminalConfigurationColumn
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var terminalProviderCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateProviderGridCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        AgentsCreateSectionHeading(title: "Provider")

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          ForEach(agentCapabilityOptions) { option in
            AgentsCreateProviderRow(
              option: option,
              selection: $formModel.selectedLaunchSelection
            )
          }
        }
        .onChange(of: formModel.selectedLaunchSelection) { _, newValue in
          let preferredRuntime = newValue.preferredRuntime
          if formModel.runtime != preferredRuntime {
            formModel.runtime = preferredRuntime
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
        terminalDetailsCard
        terminalConfigurationCard(option: option)
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
      DisclosureGroup {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          terminalTransportChoicesSection(option: option, context: context)
          terminalTransportNotice(option: option, choice: context.choice)
          terminalModelField(context: context)
          terminalEffortField(context: context)
          roleAndPersonaSection
        }
        .padding(.top, HarnessMonitorTheme.spacingSM)
      } label: {
        Text("Configure")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
      }
    }
  }

  var roleMenu: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateFieldBlock(title: "Role in session") {
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
    return AgentsCreateFieldBlock(title: "Persona (optional)") {
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
    return AgentsCreateFieldBlock(title: "If a leader already runs in this session") {
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
        AgentsCreateSectionHeading(title: "Details")

        AgentsCreateFieldBlock(
          title: "Display name",
          help: nil
        ) {
          TextField("Optional display name", text: $formModel.name)
            .harnessNativeTextField()
            .focused(focusedFieldBinding, equals: .name)
            .harnessMCPTextField(
              HarnessMonitorAccessibility.agentTuiNameField,
              label: "Display name",
              value: formModel.name
            )
            .harnessPreservePrimaryContentFocus()
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
                .harnessNativeTextField()
                .harnessMCPTextField(
                  HarnessMonitorAccessibility.agentTuiProjectDirField,
                  label: "Project directory override",
                  value: formModel.projectDir
                )
                .harnessPreservePrimaryContentFocus()
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
        AgentsCreateSectionHeading(title: "Terminal size")

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
