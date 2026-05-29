import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsDisplayPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences
  @State private var slaIsCustom = false
  @State private var slaCustomAmount: Int = 2
  @State private var slaCustomUnit: SLADurationUnit = .days

  init(
    draft: Binding<DashboardReviewsPreferences>,
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
    let hours = draft.wrappedValue.slaThresholdHours
    let startsCustom = hours != nil && !Self.slaPresets.contains(where: { $0.hours == hours })
    _slaIsCustom = State(initialValue: startsCustom)
    if startsCustom, let hours {
      let (amount, unit) = SLADurationUnit.decompose(hours: hours)
      _slaCustomAmount = State(initialValue: amount)
      _slaCustomUnit = State(initialValue: unit)
    }
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      displaySection
      slaSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane("display"))
  }

  private var displaySection: some View {
    Section {
      Toggle("Show avatars in review rows", isOn: $draft.showAvatarsInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowAvatarsToggle
        )
      Toggle("Show labels in review rows", isOn: $draft.showLabelsInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowLabelsToggle
        )
      Toggle(
        "Show +/- line counters in review rows",
        isOn: $draft.showLineCountersInRows
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsShowRowLineCountersToggle
      )
      Toggle("Show PR numbers in review rows", isOn: $draft.showPullRequestNumberInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsPullRequestNumberToggle
        )
      Toggle("Show PR age in review rows", isOn: $draft.showPullRequestAgeInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsPullRequestAgeToggle
        )
      Toggle("Wrap PR titles in review rows", isOn: $draft.wrapTitlesInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsWrapRowTitlesToggle
        )
      Stepper(
        "Wrapped title max lines: \(draft.rowTitleMaximumLines)",
        value: $draft.rowTitleMaximumLines,
        in: Self.rowTitleMaximumLinesRange
      )
      .disabled(!draft.wrapTitlesInRows)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsRowTitleMaximumLinesField
      )
      Toggle(
        "Hide semantic commit prefixes in review row titles",
        isOn: $draft.hideSemanticPrefixesInRowTitles
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsSemanticPrefixesToggle
      )
    } header: {
      Text("Display")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        These controls change the compact Reviews list only. Wrapped titles use the max-line \
        limit above, while hover help and pull request detail keep the full original title.
        """
      )
    }
  }

  private var slaSection: some View {
    Section {
      Toggle(
        "Highlight PRs exceeding SLA",
        isOn: Binding(
          get: { draft.slaThresholdHours != nil },
          set: { enabled in
            if enabled {
              slaIsCustom = false
              draft.slaThresholdHours = 48
            } else {
              draft.slaThresholdHours = nil
            }
          }
        )
      )
      .accessibilityIdentifier("settings.reviews.display.slaToggle")
      if draft.slaThresholdHours != nil {
        Picker("SLA Threshold", selection: slaSelectionBinding) {
          ForEach(Self.slaPresets, id: \.hours) { preset in
            Text(preset.label).tag(SLAThresholdSelection.preset(preset.hours))
          }
          Divider()
          Text("Custom…").tag(SLAThresholdSelection.custom)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.reviews.display.slaPicker")
      }
      if draft.slaThresholdHours != nil, slaIsCustom {
        LabeledContent("Threshold") {
          HStack(spacing: 0) {
            TextField("", value: $slaCustomAmount, format: .number)
              .textFieldStyle(.roundedBorder)
              .controlSize(.small)
              .scaledFont(.subheadline)
              .multilineTextAlignment(.trailing)
              .frame(width: 64)
            Stepper(value: $slaCustomAmount, in: slaCustomStepperRange) {}
              .labelsHidden()
              .controlSize(.small)
              .padding(.leading, 4)
            Picker("Unit", selection: $slaCustomUnit) {
              ForEach(SLADurationUnit.allCases) { unit in
                Text(unit.label).tag(unit)
              }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.leading, HarnessMonitorTheme.spacingSM)
          }
        }
        .accessibilityIdentifier("settings.reviews.display.slaStepper")
        .onChange(of: slaCustomAmount) { _, _ in commitSlaCustom() }
        .onChange(of: slaCustomUnit) { oldUnit, _ in handleSlaUnitChange(from: oldUnit) }
      }
    } header: {
      Text("SLA")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "When enabled, PRs open longer than the threshold are flagged with a badge in the review list."
      )
    }
    .onChange(of: draft.slaThresholdHours) { _, newValue in
      guard let hours = newValue else { return }
      if Self.slaPresets.contains(where: { $0.hours == hours }) {
        slaIsCustom = false
      }
    }
  }

  private var slaSelectionBinding: Binding<SLAThresholdSelection> {
    Binding(
      get: {
        guard let hours = draft.slaThresholdHours else { return .custom }
        if slaIsCustom { return .custom }
        return Self.slaPresets.contains(where: { $0.hours == hours })
          ? .preset(hours)
          : .custom
      },
      set: { selection in
        switch selection {
        case .preset(let hours):
          slaIsCustom = false
          draft.slaThresholdHours = hours
        case .custom:
          if !slaIsCustom {
            let (amount, unit) = SLADurationUnit.decompose(hours: draft.slaThresholdHours ?? 48)
            slaCustomAmount = amount
            slaCustomUnit = unit
          }
          slaIsCustom = true
        }
      }
    )
  }

  private var slaCustomStepperRange: ClosedRange<Int> {
    let upper = switch slaCustomUnit {
    case .hours: 8_760
    case .days: 365
    case .weeks: 52
    }
    return 1...upper
  }

  private func commitSlaCustom() {
    guard slaIsCustom else { return }
    let hours = max(1, slaCustomAmount * slaCustomUnit.hoursPerUnit)
    if draft.slaThresholdHours != hours {
      draft.slaThresholdHours = hours
    }
  }

  private func handleSlaUnitChange(from oldUnit: SLADurationUnit) {
    guard slaIsCustom else { return }
    let totalHours = slaCustomAmount * oldUnit.hoursPerUnit
    let converted = max(1, totalHours / slaCustomUnit.hoursPerUnit)
    let range = slaCustomStepperRange
    slaCustomAmount = min(max(converted, range.lowerBound), range.upperBound)
    commitSlaCustom()
  }

  private static let slaPresets: [(hours: Int, label: String)] = [
    (24, "1 day"),
    (48, "2 days"),
    (168, "1 week"),
    (336, "2 weeks"),
    (720, "1 month"),
  ]

  private static let rowTitleMaximumLinesRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumRowTitleMaximumLines,
      upper: DashboardReviewsPreferences.maximumRowTitleMaximumLines
    )
  )
}

private enum SLAThresholdSelection: Hashable {
  case preset(Int)
  case custom
}

private enum SLADurationUnit: String, CaseIterable, Identifiable {
  case hours
  case days
  case weeks

  var id: String { rawValue }

  var label: String {
    switch self {
    case .hours: "Hours"
    case .days: "Days"
    case .weeks: "Weeks"
    }
  }

  var hoursPerUnit: Int {
    switch self {
    case .hours: 1
    case .days: 24
    case .weeks: 168
    }
  }

  static func decompose(hours: Int) -> (amount: Int, unit: SLADurationUnit) {
    if hours >= 168, hours.isMultiple(of: 168) { return (hours / 168, .weeks) }
    if hours >= 24, hours.isMultiple(of: 24) { return (hours / 24, .days) }
    return (max(hours, 1), .hours)
  }
}
