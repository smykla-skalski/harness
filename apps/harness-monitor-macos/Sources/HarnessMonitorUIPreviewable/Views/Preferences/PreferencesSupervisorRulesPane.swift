import HarnessMonitorKit
import SwiftData
import SwiftUI

public struct PreferencesSupervisorRulesPane: View {
  let store: HarnessMonitorStore

  @State private var viewModel = PreferencesSupervisorRulesViewModel()
  @State private var persistedRowsByRuleID: [String: PolicyConfigRow] = [:]
  @State private var statusMessages: [String: String] = [:]
  @State private var errorMessages: [String: String] = [:]

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var modelContext: ModelContext? {
    store.modelContext
  }

  public var body: some View {
    Form {
      if modelContext == nil {
        Section {
          ContentUnavailableView(
            "Rules unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Rule overrides require a writable Monitor data store.")
          )
        }
      } else {
        ForEach(viewModel.rules) { rule in
          SupervisorRuleSection(
            rule: rule,
            viewModel: viewModel,
            status: statusMessages[rule.id],
            error: errorMessages[rule.id],
            onCommit: { persistRule(rule) },
            onReset: { resetRule(rule) }
          )
        }
      }
    }
    .preferencesDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesSupervisorPane("rules"))
    .task { reloadRows() }
  }

  private func reloadRows() {
    guard let modelContext else {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      return
    }
    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(sortBy: [SortDescriptor(\.ruleID)])
      let rows = try modelContext.fetch(descriptor)
      persistedRowsByRuleID = Dictionary(uniqueKeysWithValues: rows.map { ($0.ruleID, $0) })
      viewModel.applyRows(rows)
      errorMessages = [:]
    } catch {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      errorMessages = Dictionary(
        uniqueKeysWithValues: viewModel.rules.map { ($0.id, error.localizedDescription) }
      )
    }
  }

  private func persistRule(_ rule: PreferencesSupervisorRuleDescriptor) {
    guard let modelContext else { return }
    do {
      let row = try viewModel.makePolicyConfigRow(forRuleID: rule.id)
      if let persistedRow = persistedRowsByRuleID[rule.id] {
        persistedRow.enabled = row.enabled
        persistedRow.defaultBehaviorRaw = row.defaultBehaviorRaw
        persistedRow.parametersJSON = row.parametersJSON
        persistedRow.updatedAt = Date()
      } else {
        modelContext.insert(row)
      }
      try modelContext.save()
      reloadRows()
      statusMessages[rule.id] = "Saved rule override."
      errorMessages[rule.id] = nil
      Task { await store.refreshSupervisorPolicyOverrides() }
    } catch {
      statusMessages[rule.id] = nil
      errorMessages[rule.id] = error.localizedDescription
    }
  }

  private func resetRule(_ rule: PreferencesSupervisorRuleDescriptor) {
    guard let modelContext else { return }
    if let persistedRow = persistedRowsByRuleID[rule.id] {
      modelContext.delete(persistedRow)
      do {
        try modelContext.save()
      } catch {
        statusMessages[rule.id] = nil
        errorMessages[rule.id] = error.localizedDescription
        return
      }
    }
    viewModel.resetRule(ruleID: rule.id)
    reloadRows()
    statusMessages[rule.id] = "Reset to built-in defaults."
    errorMessages[rule.id] = nil
    Task { await store.refreshSupervisorPolicyOverrides() }
  }
}

private struct SupervisorRuleSection: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let viewModel: PreferencesSupervisorRulesViewModel
  let status: String?
  let error: String?
  let onCommit: () -> Void
  let onReset: () -> Void

  var body: some View {
    Section {
      Toggle(
        "Enable rule",
        isOn: Binding(
          get: { viewModel.isRuleEnabled(rule.id) },
          set: { value in
            viewModel.setRuleEnabled(value, ruleID: rule.id)
            onCommit()
          }
        )
      )
      .harnessNativeFormControl()

      Picker(
        "Default behavior",
        selection: Binding(
          get: { viewModel.ruleDefaultBehavior(ruleID: rule.id) },
          set: { value in
            viewModel.setRuleDefaultBehavior(value, ruleID: rule.id)
            onCommit()
          }
        )
      ) {
        Text("Cautious").tag(RuleDefaultBehavior.cautious)
        Text("Aggressive").tag(RuleDefaultBehavior.aggressive)
      }
      .pickerStyle(.segmented)
      .harnessNativeFormControl()

      if rule.parameters.fields.isEmpty {
        LabeledContent("Parameters") {
          Text("None").foregroundStyle(.secondary)
        }
      } else {
        ForEach(rule.parameters.fields, id: \.key) { field in
          SupervisorRuleParameterRow(
            ruleID: rule.id,
            field: field,
            viewModel: viewModel,
            onCommit: onCommit
          )
        }
      }
    } header: {
      SupervisorRuleSectionHeader(rule: rule, onReset: onReset)
    } footer: {
      SupervisorRuleSectionFooter(rule: rule, status: status, error: error)
    }
  }
}

private struct SupervisorRuleSectionHeader: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let onReset: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(rule.name)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      Button("Reset to defaults", role: .destructive, action: onReset)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesActionButton(
            "Supervisor Rules Reset \(rule.id)"
          )
        )
    }
  }
}

private struct SupervisorRuleSectionFooter: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let status: String?
  let error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline) {
        Text(rule.id)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        Text(metadataText)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let error {
        Text(error)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.danger)
      } else if let status {
        Text(status)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.accent)
      }
    }
  }

  private var metadataText: String {
    let fieldCount = rule.parameters.fields.count
    let plural = fieldCount == 1 ? "parameter" : "parameters"
    let version = Self.formatSemver(rule.version)
    return "\(fieldCount) \(plural) · \(version)"
  }

  static func formatSemver(_ version: Int) -> String {
    "v\(version)"
  }
}

private struct SupervisorRuleParameterRow: View {
  let ruleID: String
  let field: PolicyParameterSchema.Field
  let viewModel: PreferencesSupervisorRulesViewModel
  let onCommit: () -> Void

  var body: some View {
    if let allowedValues = field.allowedValues, !allowedValues.isEmpty {
      enumerationRow(allowedValues: allowedValues)
    } else {
      switch field.kind {
      case .boolean:
        booleanRow
      case .integer:
        numericRow(helpSuffix: "")
      case .duration:
        numericRow(helpSuffix: "Stored in seconds. ")
      case .string:
        stringRow
      }
    }
  }

  private var booleanRow: some View {
    LabeledContent(field.label) {
      Toggle("", isOn: booleanBinding)
        .labelsHidden()
    }
    .harnessNativeFormControl()
    .help("Default: \(field.default)")
  }

  private func numericRow(helpSuffix: String) -> some View {
    LabeledContent(field.label) {
      TextField("", value: intBinding, format: .number)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(minWidth: 140)
        .onSubmit(onCommit)
    }
    .harnessNativeFormControl()
    .help("\(helpSuffix)Default: \(field.default)")
  }

  private var stringRow: some View {
    LabeledContent(field.label) {
      TextField("", text: textBinding)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .frame(minWidth: 140)
        .onSubmit(onCommit)
    }
    .harnessNativeFormControl()
    .help("Default: \(field.default)")
  }

  private func enumerationRow(allowedValues: [String]) -> some View {
    LabeledContent(field.label) {
      Picker("", selection: enumerationBinding(allowedValues: allowedValues)) {
        ForEach(allowedValues, id: \.self) { value in
          Text(Self.enumerationDisplayName(value)).tag(value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(minWidth: 140)
    }
    .harnessNativeFormControl()
    .help("Default: \(Self.enumerationDisplayName(field.default))")
  }

  private var textBinding: Binding<String> {
    Binding(
      get: { viewModel.ruleParameterValue(for: field.key, ruleID: ruleID) },
      set: { viewModel.setRuleParameterValue($0, for: field.key, ruleID: ruleID) }
    )
  }

  private var intBinding: Binding<Int> {
    Binding(
      get: {
        Int(viewModel.ruleParameterValue(for: field.key, ruleID: ruleID))
          ?? Int(field.default) ?? 0
      },
      set: { value in
        viewModel.setRuleParameterValue(String(value), for: field.key, ruleID: ruleID)
        onCommit()
      }
    )
  }

  private var booleanBinding: Binding<Bool> {
    Binding(
      get: {
        Self.boolValue(from: viewModel.ruleParameterValue(for: field.key, ruleID: ruleID))
      },
      set: { value in
        viewModel.setRuleParameterValue(value ? "true" : "false", for: field.key, ruleID: ruleID)
        onCommit()
      }
    )
  }

  private func enumerationBinding(allowedValues: [String]) -> Binding<String> {
    Binding(
      get: {
        let current = viewModel.ruleParameterValue(for: field.key, ruleID: ruleID)
        return allowedValues.contains(current) ? current : (allowedValues.first ?? current)
      },
      set: { value in
        viewModel.setRuleParameterValue(value, for: field.key, ruleID: ruleID)
        onCommit()
      }
    )
  }

  private static func boolValue(from value: String) -> Bool {
    switch value.lowercased() {
    case "1", "true", "yes", "on":
      true
    default:
      false
    }
  }

  static func enumerationDisplayName(_ rawValue: String) -> String {
    switch rawValue {
    case "info": "Info"
    case "warn": "Warning"
    case "needsUser": "Needs user"
    case "critical": "Critical"
    default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
  }
}

#Preview("Supervisor Rules Pane") {
  PreferencesSupervisorRulesPane(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 600, height: 400)
}
