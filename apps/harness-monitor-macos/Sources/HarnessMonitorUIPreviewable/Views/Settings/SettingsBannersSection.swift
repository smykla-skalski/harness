import SwiftUI

public struct SettingsBannersSection: View {
  @AppStorage(SessionPendingDecisionBannerSettings.enabledKey)
  private var showsPendingDecisionBanners = SessionPendingDecisionBannerSettings.enabledDefaultValue

  public init() {}

  public var body: some View {
    Form {
      Section {
        Toggle("Show pending decision banners", isOn: $showsPendingDecisionBanners)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsPendingDecisionBannersToggle)
          .accessibilityLabel("Show pending decision banners")
          .accessibilityHint(
            "When disabled, session windows hide the banner that highlights pending decisions."
          )
      } header: {
        Text("Pending Decisions")
      } footer: {
        Text(
          "Controls the pending decision banner across session windows. Focus Mode has its own override when banners stay enabled here. "
            + SessionDecisionBulkActionCopy.dismissVisibleHelp
        )
        .accessibilityIdentifier("harness.settings.decisions.dismiss-visible-help")
      }
    }
    .settingsDetailFormStyle()
  }
}
