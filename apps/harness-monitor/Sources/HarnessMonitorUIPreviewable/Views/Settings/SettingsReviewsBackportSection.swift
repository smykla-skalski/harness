import HarnessMonitorKit
import SwiftUI

extension SettingsReviewsGeneralPane {
  var backportSection: some View {
    Section {
      Toggle("Detect backported PRs", isOn: $draft.backportDetectionEnabled)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsBackportDetectionToggle
        )

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Backport title regexes")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        TextEditor(text: $draft.backportPatternsText)
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 88)
          .scrollContentBackground(.hidden)
          .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor).opacity(0.42))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.8), lineWidth: 1)
          }
          .disabled(!draft.backportDetectionEnabled)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsReviewsBackportPatternsField
          )

        Button("Restore Defaults") {
          draft.restoreDefaultBackportPatterns()
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .harnessNativeFormControl()
        .fixedSize(horizontal: true, vertical: true)
        .disabled(
          draft.normalizedBackportPatterns == DashboardReviewsPreferences.defaultBackportPatterns
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsBackportRestoreButton
        )
      }
    } header: {
      Text("Backports")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Each non-empty line is matched against the PR title. Use a named `number` \
        capture or the first capture group for the source PR number.
        """
      )
    }
  }
}
