import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowCreatePane {
  @ViewBuilder
  func terminalConfigPillRow(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      if option.transportChoices.count > 1 {
        terminalTransportPill(option: option, context: context)
      }
      if !context.catalogModels.isEmpty {
        terminalModelPill(context: context)
      }
      if !context.effortValues.isEmpty {
        terminalEffortPill(context: context)
      }
      terminalRolePill
      if showsAcpFallbackRoleMenu {
        terminalFallbackRolePill
      }
      terminalPersonaPill
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func terminalTransportPill(
    option: AgentCapabilityOption,
    context: TerminalConfigurationContext
  ) -> some View {
    let label = context.choice.id.isAcp ? "ACP" : "Terminal"
    return AgentsConfigPill(
      label: label,
      value: label,
      state: .set,
      accessibilityLabel: "Transport"
    ) {
      ForEach(option.transportChoices) { transportChoice in
        let isCurrent = context.selection.wrappedValue == transportChoice.id
        Button {
          context.selection.wrappedValue = transportChoice.id
        } label: {
          checkmarkLabel(
            text: transportChoice.id.isAcp ? "ACP" : "Terminal",
            isSelected: isCurrent
          )
        }
        .disabled(!option.isEnabled(transportChoice))
      }
    }
  }

  private func terminalModelPill(
    context: TerminalConfigurationContext
  ) -> some View {
    let label = selectedTerminalModelMenuTitle(context: context)
    let currentSelection = context.modelBinding.wrappedValue
    let isCatalogDefault = context.catalogModels.contains { $0.id == currentSelection }
    let state: AgentsConfigPillState
    if currentSelection == RuntimeCustomModel.tag {
      state = .set
    } else {
      state = isCatalogDefault ? .default : .set
    }
    return AgentsConfigPill(
      label: label,
      value: label,
      state: state,
      accessibilityLabel: "Model"
    ) {
      ForEach(context.catalogModels) { model in
        Button {
          context.modelBinding.wrappedValue = model.id
        } label: {
          checkmarkLabel(text: model.displayName, isSelected: currentSelection == model.id)
        }
      }
      Button {
        context.modelBinding.wrappedValue = RuntimeCustomModel.tag
      } label: {
        checkmarkLabel(text: "Custom...", isSelected: currentSelection == RuntimeCustomModel.tag)
      }
    }
  }

  private func terminalEffortPill(
    context: TerminalConfigurationContext
  ) -> some View {
    let current = context.effortBinding.wrappedValue
    let valueText = current.isEmpty ? "Effort" : current.capitalized
    let label = valueText
    let defaultEffort = WorkspaceWindowView.defaultEffortLevel(from: context.effortValues)
    let state: AgentsConfigPillState = current == defaultEffort ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: valueText,
      state: state,
      accessibilityLabel: "Effort"
    ) {
      ForEach(context.effortValues, id: \.self) { level in
        Button {
          context.effortBinding.wrappedValue = level
        } label: {
          checkmarkLabel(text: level.capitalized, isSelected: current == level)
        }
      }
    }
  }

  private var terminalRolePill: some View {
    @Bindable var formModel = viewModel
    let role = formModel.selectedRole
    let label = role.title
    let state: AgentsConfigPillState = role == .worker ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: role.title,
      state: state,
      accessibilityLabel: "Role in session"
    ) {
      ForEach(SessionRole.allCases, id: \.self) { option in
        Button {
          formModel.selectedRole = option
        } label: {
          checkmarkLabel(text: option.title, isSelected: role == option)
        }
      }
    }
  }

  private var terminalFallbackRolePill: some View {
    @Bindable var formModel = viewModel
    let role = formModel.selectedAcpFallbackRole
    let label = "Fallback \(role.title)"
    let state: AgentsConfigPillState = role == .worker ? .default : .set
    return AgentsConfigPill(
      label: label,
      value: role.title,
      state: state,
      accessibilityLabel: "Fallback role"
    ) {
      ForEach(SessionRole.allCases.filter { $0 != .leader }, id: \.self) { option in
        Button {
          formModel.selectedAcpFallbackRole = option
        } label: {
          checkmarkLabel(text: option.title, isSelected: role == option)
        }
      }
    }
  }

  private var terminalPersonaPill: some View {
    @Bindable var formModel = viewModel
    let selected = formModel.selectedPersona
    let personaName: String? =
      selected.flatMap { id in
        viewModel.availablePersonas.first(where: { $0.identifier == id })?.name
      }
    let label = personaName ?? "Persona"
    let state: AgentsConfigPillState = personaName == nil ? .additive : .set
    return AgentsConfigPill(
      label: label,
      value: personaName ?? "None",
      state: state,
      accessibilityLabel: "Persona"
    ) {
      Button {
        formModel.selectedPersonaID = ""
      } label: {
        checkmarkLabel(text: "None", isSelected: selected == nil || selected?.isEmpty == true)
      }
      ForEach(viewModel.availablePersonas, id: \.identifier) { persona in
        Button {
          formModel.selectedPersonaID = persona.identifier
        } label: {
          checkmarkLabel(text: persona.name, isSelected: selected == persona.identifier)
        }
      }
    }
  }

  @ViewBuilder
  private func checkmarkLabel(text: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(text, systemImage: "checkmark")
    } else {
      Text(text)
    }
  }

}
