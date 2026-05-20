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
    if SessionWindowCreateFormCatalogs.shouldSurfaceInlineUnavailableReason(for: option),
      let unavailableReason = SessionWindowCreateFormCatalogs.unavailableReason(
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

    if SessionWindowCreateFormCatalogs.shouldShowTransportDiagnosticsDisclosure(for: option) {
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
          "Model",
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
          LabeledContent("Custom model") {
            TextField("", text: codexCustomModel)
              .harnessNativeTextField()
              .accessibilityLabel("Custom Codex model")
          }
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
        LabeledContent("Model (optional)") {
          TextField("", text: codexCustomModel)
            .harnessNativeTextField()
            .accessibilityLabel("Codex model")
        }

        LabeledContent("Effort (optional)") {
          TextField("", text: codexEffortText)
            .harnessNativeTextField()
            .accessibilityLabel("Codex effort")
        }
      }
    } header: {
      Text("Codex")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Choose the run mode, model, and effort for this draft")
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

  func selectedRuntimeModelMenuTitle(
    runtimeKey: String,
    catalog: RuntimeModelCatalog
  ) -> String {
    let selectedModelID = currentRuntimeModelPickerValue(
      for: runtimeKey,
      catalog: catalog
    )
    if selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
      let customModelID = currentRuntimeCustomModel(for: runtimeKey)
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
    runtimeModelPickerSelection(for: runtime.rawValue, catalog: catalog)
  }

  func currentRuntimeModelPickerValue(
    for runtimeKey: String,
    catalog: RuntimeModelCatalog
  ) -> String {
    if let stored = draft.modelByRuntime[runtimeKey], !stored.isEmpty {
      return stored
    }
    return catalog.default
  }

  func updateRuntimeModelPickerSelection(
    _ newValue: String,
    for runtimeKey: String
  ) {
    var next = draft
    next.modelByRuntime[runtimeKey] = newValue
    if newValue != SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
      next.customModelByRuntime[runtimeKey] = nil
    }
    state.updateCreateDraft(next)
  }

  func runtimeModelPickerSelection(
    for runtimeKey: String,
    catalog: RuntimeModelCatalog
  ) -> Binding<String> {
    Binding(
      get: { currentRuntimeModelPickerValue(for: runtimeKey, catalog: catalog) },
      set: { updateRuntimeModelPickerSelection($0, for: runtimeKey) }
    )
  }

  func terminalCustomModel(
    for runtime: AgentTuiRuntime
  ) -> Binding<String> {
    runtimeCustomModel(for: runtime.rawValue)
  }

  func runtimeCustomModel(
    for runtimeKey: String
  ) -> Binding<String> {
    Binding(
      get: { currentRuntimeCustomModel(for: runtimeKey) },
      set: { updateRuntimeCustomModel($0, for: runtimeKey) }
    )
  }

  func currentRuntimeCustomModel(
    for runtimeKey: String
  ) -> String {
    draft.customModelByRuntime[runtimeKey] ?? ""
  }

  func updateRuntimeCustomModel(
    _ value: String,
    for runtimeKey: String
  ) {
    var next = draft
    next.modelByRuntime[runtimeKey] =
      SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
    next.customModelByRuntime[runtimeKey] = value
    state.updateCreateDraft(next)
  }

  func terminalEffortValues(
    for runtime: AgentTuiRuntime,
    catalog: RuntimeModelCatalog
  ) -> [String] {
    runtimeEffortValues(for: runtime.rawValue, catalog: catalog)
  }

  func runtimeEffortValues(
    for runtimeKey: String,
    catalog: RuntimeModelCatalog
  ) -> [String] {
    SessionWindowCreateFormCatalogs.effortValues(
      catalog: catalog,
      selectedModelID: currentRuntimeModelPickerValue(
        for: runtimeKey,
        catalog: catalog
      )
    )
  }

  func terminalEffortSelection(
    for runtime: AgentTuiRuntime,
    values: [String]
  ) -> Binding<String> {
    runtimeEffortSelection(for: runtime.rawValue, values: values)
  }

  func runtimeEffortSelection(
    for runtimeKey: String,
    values: [String]
  ) -> Binding<String> {
    Binding(
      get: { resolvedRuntimeEffortSelection(for: runtimeKey, values: values) },
      set: { updateRuntimeEffort($0, for: runtimeKey) }
    )
  }

  func resolvedRuntimeEffortSelection(
    for runtimeKey: String,
    values: [String]
  ) -> String {
    guard let current = draft.effortByRuntime[runtimeKey], values.contains(current) else {
      return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: values)
    }
    return current
  }

  func updateRuntimeEffort(
    _ value: String,
    for runtimeKey: String
  ) {
    var next = draft
    next.effortByRuntime[runtimeKey] = value
    state.updateCreateDraft(next)
  }
}
