import HarnessMonitorKit
import SwiftUI

extension SessionWindowCreateForm {
  func selectProvider(_ option: AgentCapabilityOption) {
    launchSelection.wrappedValue = option.normalizedSelection(for: launchSelection.wrappedValue)
  }

  @ViewBuilder
  func terminalTransportNotice(
    option: AgentCapabilityOption,
    choice: AgentCapabilityTransportChoice
  ) -> some View {
    if let unavailableReason = SessionWindowCreateFormCatalogs.unavailableReason(
      for: option,
      choice: choice
    ),
      !option.isEnabled(choice)
    {
      Label {
        Text(unavailableReason)
          .scaledFont(.caption)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .foregroundStyle(HarnessMonitorTheme.caution)
      .accessibilityElement(children: .combine)
    }

    if option.showsInstallCTA {
      HarnessMonitorActionButton(
        title: option.installActionTitle,
        tint: HarnessMonitorTheme.caution,
        variant: .prominent,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentCapabilityInstallButton(
          option.id),
        fillsWidth: false
      ) {
        HarnessMonitorClipboard.copy(SessionWindowCreateFormCatalogs.installHintText(for: option))
      }
      .help(SessionWindowCreateFormCatalogs.installHintText(for: option))
      .accessibilityHint(option.installAccessibilityHint ?? "")
    }

    if option.availabilityState == .checkingAccess
      || option.availabilityState == .setupRequired
      || option.availabilityState == .bridgeAccessRequired
      || option.availabilityState == .unavailable
    {
      SessionWindowCreateDiagnosticsDisclosure(option: option)
    }
  }

  var codexConfigurationSection: some View {
    Section {
      Picker("Run mode", selection: codexMode) {
        ForEach(CodexRunMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .harnessNativeFormControl()
      .accessibilityLabel("Codex mode")

      if let codexCatalog {
        Picker(
          selectedCodexModelMenuTitle(catalog: codexCatalog),
          selection: codexModelPickerSelection
        ) {
          ForEach(codexCatalog.models) { model in
            Text(model.displayName).tag(model.id)
          }
          Text("Custom...")
            .tag(SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag)
        }
        .pickerStyle(.menu)
        .harnessNativeFormControl()
        .accessibilityLabel("Codex model")

        if codexModelPickerSelection.wrappedValue
          == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        {
          TextField("Provider-specific model id", text: codexCustomModel)
            .harnessNativeTextField()
            .accessibilityLabel("Custom Codex model")
        }

        if !codexEffortValues.isEmpty {
          Picker("Effort", selection: codexEffortSelection) {
            ForEach(codexEffortValues, id: \.self) { level in
              Text(level.capitalized).tag(level)
            }
          }
          .pickerStyle(.segmented)
          .harnessNativeFormControl()
          .accessibilityLabel("Codex effort")
        }
      } else {
        TextField("Model (optional)", text: codexCustomModel)
          .harnessNativeTextField()
          .accessibilityLabel("Codex model")

        TextField("Effort (optional)", text: codexEffortText)
          .harnessNativeTextField()
          .accessibilityLabel("Codex effort")
      }
    } header: {
      Text("Codex")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Choose the run mode, model, and effort for this draft.")
        .harnessNativeFormSectionFooter()
    }
  }

  var codexEffortText: Binding<String> {
    Binding(
      get: { draft.codexEffort },
      set: { updateDraft(codexEffort: $0) }
    )
  }

  func selectedTerminalModelMenuTitle(
    runtime: AgentTuiRuntime,
    catalog: RuntimeModelCatalog
  ) -> String {
    let selectedModelID = terminalModelPickerSelection(for: runtime, catalog: catalog).wrappedValue
    if selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
      let customModelID = terminalCustomModel(for: runtime).wrappedValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return customModelID.isEmpty ? "Custom model" : customModelID
    }

    return
      catalog.models.first { $0.id == selectedModelID }?.displayName
      ?? selectedModelID
  }

  func selectedCodexModelMenuTitle(catalog: RuntimeModelCatalog) -> String {
    let selectedModelID = codexModelPickerSelection.wrappedValue
    if selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
      let customModelID = codexCustomModel.wrappedValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      return customModelID.isEmpty ? "Custom model" : customModelID
    }

    return
      catalog.models.first { $0.id == selectedModelID }?.displayName
      ?? selectedModelID
  }

  func terminalModelPickerSelection(
    for runtime: AgentTuiRuntime,
    catalog: RuntimeModelCatalog
  ) -> Binding<String> {
    Binding(
      get: {
        if let stored = draft.modelByRuntime[runtime.rawValue], !stored.isEmpty {
          return stored
        }
        return catalog.default
      },
      set: { newValue in
        var next = draft
        next.modelByRuntime[runtime.rawValue] = newValue
        if newValue != SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
          next.customModelByRuntime[runtime.rawValue] = nil
        }
        state.updateCreateDraft(next)
      }
    )
  }

  func terminalCustomModel(
    for runtime: AgentTuiRuntime
  ) -> Binding<String> {
    Binding(
      get: { draft.customModelByRuntime[runtime.rawValue] ?? "" },
      set: {
        var next = draft
        next.modelByRuntime[runtime.rawValue] =
          SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        next.customModelByRuntime[runtime.rawValue] = $0
        state.updateCreateDraft(next)
      }
    )
  }

  func terminalEffortValues(
    for runtime: AgentTuiRuntime,
    catalog: RuntimeModelCatalog
  ) -> [String] {
    SessionWindowCreateFormCatalogs.effortValues(
      catalog: catalog,
      selectedModelID: terminalModelPickerSelection(for: runtime, catalog: catalog).wrappedValue
    )
  }

  func terminalEffortSelection(
    for runtime: AgentTuiRuntime,
    values: [String]
  ) -> Binding<String> {
    Binding(
      get: {
        guard let current = draft.effortByRuntime[runtime.rawValue], values.contains(current) else {
          return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: values)
        }
        return current
      },
      set: {
        var next = draft
        next.effortByRuntime[runtime.rawValue] = $0
        state.updateCreateDraft(next)
      }
    )
  }
}
