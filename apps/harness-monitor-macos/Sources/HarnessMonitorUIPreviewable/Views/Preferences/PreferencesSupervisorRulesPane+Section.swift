import HarnessMonitorKit
import SwiftUI

struct SupervisorRuleSection: View {
  let rule: PreferencesSupervisorRuleDescriptor
  let viewModel: PreferencesSupervisorRulesViewModel
  let status: String?
  let error: String?
  let onCommit: () -> Void
  let onReset: () -> Void

  var body: some View {
    Section {
      LabeledContent("Enable rule") {
        Toggle(
          "",
          isOn: Binding(
            get: { viewModel.isRuleEnabled(rule.id) },
            set: { value in
              viewModel.setRuleEnabled(value, ruleID: rule.id)
              onCommit()
            }
          )
        )
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
        .scaledFont(.subheadline)
      }
      .harnessNativeFormControl()

      LabeledContent("Default behavior") {
        Picker(
          "",
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
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .scaledFont(.subheadline)
        .fixedSize()
      }
      .harnessNativeFormControl()

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
