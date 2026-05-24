import SwiftUI

public struct SettingsBannersSection: View {
  public let isActive: Bool
  @AppStorage(SessionPendingDecisionBannerSettings.enabledKey)
  private var showsPendingDecisionBanners = SessionPendingDecisionBannerSettings.enabledDefaultValue

  public init(isActive: Bool = true) {
    self.isActive = isActive
  }

  public var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      Section {
        Toggle("Show pending decision banners", isOn: $showsPendingDecisionBanners)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsPendingDecisionBannersToggle)
          .accessibilityLabel("Show pending decision banners")
          .accessibilityHint(
            "When disabled, session windows hide the banner that highlights pending decisions"
          )
      } header: {
        Text("Pending Decisions")
      } footer: {
        Text(
          "Controls the pending decision banner across session windows. "
            + "Focus Mode has its own override when banners stay enabled here"
        )
      }
    }
    .settingsDetailFormStyle()
  }
}
