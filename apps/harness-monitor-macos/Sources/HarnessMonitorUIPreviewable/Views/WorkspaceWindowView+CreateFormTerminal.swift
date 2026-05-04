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

        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: 220), spacing: HarnessMonitorTheme.itemSpacing)
          ],
          alignment: .leading,
          spacing: HarnessMonitorTheme.itemSpacing
        ) {
          ForEach(agentCapabilityOptions) { option in
            AgentsCreateProviderRow(
              option: option,
              selection: $formModel.selectedLaunchSelection
            )
          }
        }
        .onChange(of: formModel.selectedLaunchSelection) { _, newValue in
          formModel.didApplyLaunchSelectionAutoDefault = true
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
      terminalSelectedColumn(option: option)
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

  private func terminalSelectedColumn(option: AgentCapabilityOption) -> some View {
    @Bindable var formModel = viewModel
    let context = terminalConfigurationContext(for: option)
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

        terminalAdvancedOverrides

        terminalConfigPillRow(option: option, context: context)
        terminalTransportNotice(option: option, choice: context.choice)
        terminalCustomModelField(context: context)
      }
    }
  }

  @ViewBuilder
  private var terminalAdvancedOverrides: some View {
    @Bindable var formModel = viewModel
    WholeRowDisclosure(label: "Advanced overrides") {
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
    }
  }

  @ViewBuilder
  private func terminalCustomModelField(context: TerminalConfigurationContext) -> some View {
    if context.modelBinding.wrappedValue == RuntimeCustomModel.tag {
      AgentsCreateFieldBlock(
        title: "Custom model id",
        help: "Provider-specific identifier - e.g. claude-sonnet-4-5-20250929"
      ) {
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

}

private struct WholeRowDisclosure<Content: View>: View {
  let label: String
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Image(systemName: "chevron.right")
            .scaledFont(.caption.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityHidden(true)
          Text(label)
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityValue(isExpanded ? "expanded" : "collapsed")
      .accessibilityAddTraits(.isButton)

      if isExpanded {
        content()
          .padding(.top, HarnessMonitorTheme.spacingXS)
      }
    }
  }
}
