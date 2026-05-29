import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsDisplayPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences
  @State private var slaIsCustom = false

  init(
    draft: Binding<DashboardReviewsPreferences>,
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
    let hours = draft.wrappedValue.slaThresholdHours
    let startsCustom = hours != nil && !Self.slaPresets.contains(where: { $0.hours == hours })
    _slaIsCustom = State(initialValue: startsCustom)
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
            TextField(
              "",
              value: Binding(
                get: { draft.slaThresholdHours ?? 48 },
                set: { draft.slaThresholdHours = max(1, $0) }
              ),
              format: .number
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .scaledFont(.subheadline)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            Stepper(
              value: Binding(
                get: { draft.slaThresholdHours ?? 48 },
                set: { draft.slaThresholdHours = max(1, $0) }
              ),
              in: 1...8_760
            ) {}
              .labelsHidden()
              .controlSize(.small)
              .padding(.leading, 4)
            Text("hours")
              .foregroundStyle(.secondary)
              .padding(.leading, HarnessMonitorTheme.spacingSM)
          }
        }
        .accessibilityIdentifier("settings.reviews.display.slaStepper")
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
          slaIsCustom = true
          if draft.slaThresholdHours == nil {
            draft.slaThresholdHours = 48
          }
        }
      }
    )
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
