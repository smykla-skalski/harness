import SwiftUI

public struct SettingsFocusModeSection: View {
  @AppStorage(SessionPendingDecisionBannerSettings.focusModeEnabledKey)
  private var showsPendingDecisionBannersInFocusMode =
    SessionPendingDecisionBannerSettings.focusModeEnabledDefaultValue

  public init() {}

  public var body: some View {
    Form {
      Section {
        Toggle(
          "Show pending decision banners in Focus mode",
          isOn: $showsPendingDecisionBannersInFocusMode
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsPendingBannersFocusModeToggle
        )
        .accessibilityLabel("Show pending decision banners in Focus mode")
        .accessibilityHint(
          "When disabled, Focus mode hides the pending decision banner even while "
            + "banners stay enabled elsewhere."
        )
      } header: {
        Text("Pending Decisions")
      } footer: {
        Text(
          "Controls whether Focus mode keeps the pending decision banner visible. "
            + "This setting takes effect when the Banners page keeps pending "
            + "decision banners enabled."
        )
      }
    }
    .settingsDetailFormStyle()
  }
}
