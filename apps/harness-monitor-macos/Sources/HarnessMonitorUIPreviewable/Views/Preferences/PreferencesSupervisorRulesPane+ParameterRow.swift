import HarnessMonitorKit
import SwiftUI

struct SupervisorRuleParameterRow: View {
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
      set: {
        viewModel.setRuleParameterValue($0, for: field.key, ruleID: ruleID)
        onCommit()
      }
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
