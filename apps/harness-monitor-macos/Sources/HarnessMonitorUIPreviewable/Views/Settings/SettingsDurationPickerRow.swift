import HarnessMonitorKit
import SwiftUI

enum SettingsDurationUnit: String, CaseIterable, Identifiable, Sendable {
  case seconds
  case minutes
  case hours

  var id: String { rawValue }

  var secondsPerUnit: UInt64 {
    switch self {
    case .seconds: 1
    case .minutes: 60
    case .hours: 3600
    }
  }

  var label: String {
    switch self {
    case .seconds: "Seconds"
    case .minutes: "Minutes"
    case .hours: "Hours"
    }
  }
}

struct SettingsDurationDecomposition: Equatable {
  let amount: UInt64
  let unit: SettingsDurationUnit

  init(amount: UInt64, unit: SettingsDurationUnit) {
    self.amount = amount
    self.unit = unit
  }

  init(seconds: UInt64) {
    if seconds >= 3600, seconds.isMultiple(of: 3600) {
      unit = .hours
      amount = seconds / 3600
    } else if seconds >= 60, seconds.isMultiple(of: 60) {
      unit = .minutes
      amount = seconds / 60
    } else {
      unit = .seconds
      amount = seconds
    }
  }

  var seconds: UInt64 { amount * unit.secondsPerUnit }
}

enum SettingsDurationSelection: Hashable {
  case preset(UInt64)
  case custom
}

enum SettingsDurationFormatter {
  static func presetLabel(seconds: UInt64) -> String {
    if seconds >= 3600, seconds.isMultiple(of: 3600) {
      let hours = seconds / 3600
      return hours == 1 ? "Every 1 hour" : "Every \(hours) hours"
    }
    if seconds >= 60, seconds.isMultiple(of: 60) {
      let minutes = seconds / 60
      return minutes == 1 ? "Every 1 minute" : "Every \(minutes) minutes"
    }
    return seconds == 1 ? "Every 1 second" : "Every \(seconds) seconds"
  }
}

struct SettingsDurationPickerRow: View {
  let title: String
  let presets: [UInt64]
  let minSeconds: UInt64
  @Binding var seconds: UInt64
  let pickerAccessibilityIdentifier: String

  @State private var isCustom = false
  @State private var customAmount: UInt64 = 1
  @State private var customUnit: SettingsDurationUnit = .minutes

  var body: some View {
    Picker(title, selection: selectionBinding) {
      ForEach(presets, id: \.self) { value in
        Text(SettingsDurationFormatter.presetLabel(seconds: value))
          .tag(SettingsDurationSelection.preset(value))
      }
      Divider()
      Text("Custom…").tag(SettingsDurationSelection.custom)
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(pickerAccessibilityIdentifier)
    .onChange(of: seconds, initial: true) { _, newValue in
      syncFromExternalSeconds(newValue)
    }

    if isCustom {
      customRow
    }
  }

  private var selectionBinding: Binding<SettingsDurationSelection> {
    Binding(
      get: { isCustom ? .custom : .preset(seconds) },
      set: { newValue in
        switch newValue {
        case .preset(let value):
          isCustom = false
          if seconds != value { seconds = value }
        case .custom:
          if !isCustom {
            let decomposition = SettingsDurationDecomposition(seconds: seconds)
            customAmount = max(decomposition.amount, 1)
            customUnit = decomposition.unit
          }
          isCustom = true
        }
      }
    )
  }

  private var customRow: some View {
    LabeledContent("Every") {
      HStack(spacing: 0) {
        TextField("", value: $customAmount, format: .number)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .scaledFont(.subheadline)
          .multilineTextAlignment(.trailing)
          .frame(width: 64)
        Stepper(value: $customAmount, in: stepperRange) {}
          .labelsHidden()
          .controlSize(.small)
          .padding(.leading, 4)
        Picker("Unit", selection: $customUnit) {
          ForEach(SettingsDurationUnit.allCases) { unit in
            Text(unit.label).tag(unit)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .padding(.leading, HarnessMonitorTheme.spacingSM)
      }
    }
    .onChange(of: customAmount) { _, _ in commitCustom() }
    .onChange(of: customUnit) { _, oldUnit in handleUnitChange(from: oldUnit) }
  }

  private var stepperRange: ClosedRange<UInt64> {
    let lowerBound: UInt64
    let upperBound: UInt64
    switch customUnit {
    case .seconds:
      lowerBound = max(minSeconds, 1)
      upperBound = 86_400
    case .minutes:
      lowerBound = max((minSeconds + 59) / 60, 1)
      upperBound = 1_440
    case .hours:
      lowerBound = max((minSeconds + 3599) / 3600, 1)
      upperBound = 168
    }
    return lowerBound...max(lowerBound, upperBound)
  }

  private func commitCustom() {
    guard isCustom else { return }
    let raw = customAmount * customUnit.secondsPerUnit
    let clamped = max(raw, minSeconds)
    if clamped != seconds { seconds = clamped }
  }

  private func handleUnitChange(from oldUnit: SettingsDurationUnit) {
    guard isCustom else { return }
    let range = stepperRange
    if customAmount < range.lowerBound {
      customAmount = range.lowerBound
    } else if customAmount > range.upperBound {
      customAmount = range.upperBound
    }
    _ = oldUnit
    commitCustom()
  }

  private func syncFromExternalSeconds(_ value: UInt64) {
    if isCustom {
      let derived = max(customAmount * customUnit.secondsPerUnit, minSeconds)
      if derived == value { return }
    }
    if presets.contains(value) {
      isCustom = false
      return
    }
    let decomposition = SettingsDurationDecomposition(seconds: value)
    customAmount = max(decomposition.amount, 1)
    customUnit = decomposition.unit
    isCustom = true
  }
}
