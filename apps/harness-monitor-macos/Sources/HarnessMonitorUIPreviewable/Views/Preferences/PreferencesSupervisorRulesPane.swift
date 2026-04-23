import HarnessMonitorKit
import SwiftData
import SwiftUI

public struct PreferencesSupervisorRulesPane: View {
  let store: HarnessMonitorStore

  @State private var viewModel = PreferencesSupervisorRulesViewModel()
  @State private var persistedRowsByRuleID: [String: PolicyConfigRow] = [:]
  @State private var statusMessage: String?
  @State private var errorMessage: String?

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var modelContext: ModelContext? {
    store.modelContext
  }

  public var body: some View {
    Group {
      if modelContext == nil {
        ContentUnavailableView(
          "Rules unavailable",
          systemImage: "externaldrive.badge.exclamationmark",
          description: Text("Rule overrides require a writable Monitor data store.")
        )
      } else {
        HSplitView {
          sidebar
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
          editor
            .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesSupervisorPane("rules"))
    .task {
      reloadRows()
    }
  }

  private var sidebar: some View {
    List(viewModel.rules, selection: selectedRuleBinding) { rule in
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(rule.name)
          .scaledFont(.body.bold())
        Text(rule.id)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .tag(rule.id)
    }
  }

  private var editor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        if let selectedRule = viewModel.selectedRule {
          header(for: selectedRule)

          Toggle("Enable rule", isOn: enabledBinding)

          Picker("Default behavior", selection: defaultBehaviorBinding) {
            Text("Cautious").tag(RuleDefaultBehavior.cautious)
            Text("Aggressive").tag(RuleDefaultBehavior.aggressive)
          }
          .pickerStyle(.segmented)

          if selectedRule.parameters.fields.isEmpty {
            Text("This rule has no configurable parameters.")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          } else {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
              Text("Parameters")
                .scaledFont(.headline)
              ForEach(selectedRule.parameters.fields, id: \.key) { field in
                parameterEditor(for: field)
              }
            }
          }

          if let statusMessage {
            Text(statusMessage)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.accent)
          }
          if let errorMessage {
            Text(errorMessage)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.danger)
          }

          HStack(spacing: HarnessMonitorTheme.spacingSM) {
            HarnessMonitorActionButton(
              title: "Save",
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
                "Supervisor Rules Save"
              ),
              action: saveSelectedRule
            )
            HarnessMonitorActionButton(
              title: "Reset",
              variant: .bordered,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
                "Supervisor Rules Reset"
              ),
              action: resetSelectedRule
            )
          }
        }
      }
      .padding()
    }
  }

  private var selectedRuleBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedRuleID },
      set: { newValue in
        guard let newValue else {
          return
        }
        statusMessage = nil
        errorMessage = nil
        viewModel.selectRule(id: newValue)
      }
    )
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { viewModel.enabled },
      set: { viewModel.enabled = $0 }
    )
  }

  private var defaultBehaviorBinding: Binding<RuleDefaultBehavior> {
    Binding(
      get: { viewModel.defaultBehavior },
      set: { viewModel.defaultBehavior = $0 }
    )
  }

  private func header(for rule: PreferencesSupervisorRuleDescriptor) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(rule.name)
        .scaledFont(.title3.bold())
      Text(rule.id)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Version \(rule.version) · \(rule.parameters.fields.count) parameter fields")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  @ViewBuilder
  private func parameterEditor(for field: PolicyParameterSchema.Field) -> some View {
    switch field.kind {
    case .boolean:
      Toggle(field.label, isOn: booleanBinding(for: field.key))
      Text("Default: \(field.default)")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    case .duration:
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        TextField(field.label, text: textBinding(for: field.key))
          .textFieldStyle(.roundedBorder)
        Text("Stored in seconds. Default: \(field.default)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    case .integer, .string:
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        TextField(field.label, text: textBinding(for: field.key))
          .textFieldStyle(.roundedBorder)
        Text("Default: \(field.default)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
  }

  private func textBinding(for key: String) -> Binding<String> {
    Binding(
      get: { viewModel.parameterValue(for: key) },
      set: { viewModel.setParameterValue($0, for: key) }
    )
  }

  private func booleanBinding(for key: String) -> Binding<Bool> {
    Binding(
      get: { Self.boolValue(from: viewModel.parameterValue(for: key)) },
      set: { viewModel.setParameterValue($0 ? "true" : "false", for: key) }
    )
  }

  private func reloadRows() {
    guard let modelContext else {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      return
    }

    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(
        sortBy: [SortDescriptor(\.ruleID)]
      )
      let rows = try modelContext.fetch(descriptor)
      persistedRowsByRuleID = Dictionary(uniqueKeysWithValues: rows.map { ($0.ruleID, $0) })
      viewModel.applyRows(rows)
      errorMessage = nil
    } catch {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      errorMessage = error.localizedDescription
    }
  }

  private func saveSelectedRule() {
    guard
      let modelContext,
      let selectedRuleID = viewModel.selectedRuleID
    else {
      return
    }

    do {
      let row = try viewModel.makePolicyConfigRow()
      if let persistedRow = persistedRowsByRuleID[selectedRuleID] {
        persistedRow.enabled = row.enabled
        persistedRow.defaultBehaviorRaw = row.defaultBehaviorRaw
        persistedRow.parametersJSON = row.parametersJSON
        persistedRow.updatedAt = Date()
      } else {
        modelContext.insert(row)
      }
      try modelContext.save()
      reloadRows()
      statusMessage = "Saved rule override."
      errorMessage = nil
      Task {
        await store.refreshSupervisorPolicyOverrides()
      }
    } catch {
      statusMessage = nil
      errorMessage = error.localizedDescription
    }
  }

  private func resetSelectedRule() {
    guard
      let modelContext,
      let selectedRuleID = viewModel.selectedRuleID
    else {
      return
    }

    if let persistedRow = persistedRowsByRuleID[selectedRuleID] {
      modelContext.delete(persistedRow)
      do {
        try modelContext.save()
      } catch {
        statusMessage = nil
        errorMessage = error.localizedDescription
        return
      }
    }

    reloadRows()
    viewModel.selectRule(id: selectedRuleID)
    viewModel.resetSelectedRule()
    statusMessage = "Reset to built-in defaults."
    errorMessage = nil
    Task {
      await store.refreshSupervisorPolicyOverrides()
    }
  }

  private static func boolValue(from value: String) -> Bool {
    switch value.lowercased() {
    case "1", "true", "yes", "on":
      true
    default:
      false
    }
  }
}

#Preview("Supervisor Rules Pane") {
  PreferencesSupervisorRulesPane(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 600, height: 400)
}
