import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsDisplayPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences

  init(
    draft: Binding<DashboardReviewsPreferences>,
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
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
      Toggle("Show approval counts in review rows", isOn: $draft.showApprovalCountsInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsApprovalCountsToggle
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

  private static let rowTitleMaximumLinesRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumRowTitleMaximumLines,
      upper: DashboardReviewsPreferences.maximumRowTitleMaximumLines
    )
  )
}
