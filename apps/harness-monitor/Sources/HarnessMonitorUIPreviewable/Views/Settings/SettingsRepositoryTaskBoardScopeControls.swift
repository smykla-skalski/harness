import SwiftUI

struct SettingsRepositoryTaskBoardScopeControls: View {
  @Binding var draft: SettingsSharedRepositoriesDraft
  let enabledCount: Int
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Task Board scope")
          .font(captionSemibold)
        Text("\(enabledCount) of \(draft.rows.count) repositories enabled")
          .font(captionFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsRepoTaskBoardScopeSummary
          )
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Enable All") {
        draft.setTaskBoardEnabledForAll(true)
      }
      .buttonStyle(.borderless)
      .frame(minHeight: 24)
      .contentShape(Rectangle())
      .disabled(enabledCount == draft.rows.count)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepoTaskBoardEnableAllButton
      )

      Button("Disable All") {
        draft.setTaskBoardEnabledForAll(false)
      }
      .buttonStyle(.borderless)
      .frame(minHeight: 24)
      .contentShape(Rectangle())
      .disabled(enabledCount == 0)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepoTaskBoardDisableAllButton
      )
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }
}
