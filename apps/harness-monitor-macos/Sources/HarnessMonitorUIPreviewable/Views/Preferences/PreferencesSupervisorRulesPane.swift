import HarnessMonitorKit
import SwiftData
import SwiftUI

public struct PreferencesSupervisorRulesPane: View {
  let store: HarnessMonitorStore

  private static let statusDisplayDuration: Duration = .seconds(2)

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
      showTransientStatus("Saved rule override", for: rule.id)
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
    showTransientStatus("Reset to built-in defaults", for: rule.id)
    errorMessages[rule.id] = nil
    Task { await store.refreshSupervisorPolicyOverrides() }
  }

  private func showTransientStatus(_ message: String, for ruleID: String) {
    withAnimation(.easeOut(duration: 0.15)) {
      statusMessages[ruleID] = message
    }
    Task {
      try? await Task.sleep(for: Self.statusDisplayDuration)
      await MainActor.run {
        if statusMessages[ruleID] == message {
          withAnimation(.easeOut(duration: 0.15)) {
            statusMessages[ruleID] = nil
          }
        }
      }
    }
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
      .scaledFont(.subheadline)

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
      .scaledFont(.subheadline)

      if !rule.parameters.fields.isEmpty {
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
      SupervisorRuleSectionHeader(
        rule: rule,
        status: status,
        canReset: !viewModel.isRuleAtBuiltInDefaults(rule.id),
        onReset: onReset
      )
    } footer: {
      SupervisorRuleSectionFooter(rule: rule, error: error)
    }
  }
}

private struct SupervisorRuleSectionHeader: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let status: String?
  let canReset: Bool
  let onReset: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(rule.name)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      if let status {
        Text(status)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.accent)
          .transition(.opacity)
      }
      Button("Reset", action: onReset)
        .disabled(!canReset)
        .controlSize(.small)
        .scaledFont(.subheadline)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesActionButton(
            "Supervisor Rules Reset \(rule.id)"
          )
        )
    }
    .animation(.easeOut(duration: 0.15), value: status)
  }
}

private struct SupervisorRuleSectionFooter: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: rule.id)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        Text(verbatim: Self.formatSemver(rule.version))
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let error {
        Text(error)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.danger)
      }
    }
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
        .scaledFont(.subheadline)
    }
    .harnessNativeFormControl()
    .help("Default: \(field.default)")
  }

  private func numericRow(helpSuffix: String) -> some View {
    LabeledContent(field.label) {
      HStack(spacing: 0) {
        TextField("", value: editableIntBinding, format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .scaledFont(.subheadline)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 72)
          .onSubmit(onCommit)
        Stepper {
          EmptyView()
        } onIncrement: {
          adjustNumericValue(by: 1)
        } onDecrement: {
          adjustNumericValue(by: -1)
        }
          .labelsHidden()
          .controlSize(.small)
      }
    }
    .harnessNativeFormControl()
    .scaledFont(.subheadline)
    .help("\(helpSuffix)Default: \(field.default)")
  }

  private var stringRow: some View {
    LabeledContent(field.label) {
      TextField("", text: textBinding)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .scaledFont(.subheadline)
        .labelsHidden()
        .frame(minWidth: 140)
        .onSubmit(onCommit)
    }
    .harnessNativeFormControl()
    .help("Default: \(field.default)")
  }

  private func enumerationRow(allowedValues: [String]) -> some View {
    LabeledContent(field.label) {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        Picker("", selection: enumerationBinding(allowedValues: allowedValues)) {
          ForEach(allowedValues, id: \.self) { value in
            Text(Self.enumerationDisplayName(value)).tag(value)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .scaledFont(.subheadline)
        .frame(width: 140, alignment: .trailing)
      }
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

  private var editableIntBinding: Binding<Int> {
    Binding(
      get: {
        Int(viewModel.ruleParameterValue(for: field.key, ruleID: ruleID))
          ?? Int(field.default) ?? 0
      },
      set: { value in
        viewModel.setRuleParameterValue(String(value), for: field.key, ruleID: ruleID)
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

  private func adjustNumericValue(by delta: Int) {
    let currentValue = editableIntBinding.wrappedValue
    let nextValue: Int

    if delta >= 0 {
      let (candidate, overflowed) = currentValue.addingReportingOverflow(delta)
      nextValue = overflowed ? Int.max : candidate
    } else {
      let magnitude = delta.magnitude
      let (candidate, overflowed) = currentValue.subtractingReportingOverflow(Int(magnitude))
      nextValue = overflowed ? Int.min : candidate
    }

    let clampedValue: Int
    switch field.kind {
    case .duration:
      clampedValue = max(0, nextValue)
    case .integer, .boolean, .string:
      clampedValue = nextValue
    }

    editableIntBinding.wrappedValue = clampedValue
    onCommit()
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
