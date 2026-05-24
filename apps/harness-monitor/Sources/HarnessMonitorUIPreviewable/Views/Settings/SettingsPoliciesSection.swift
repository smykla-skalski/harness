import SwiftUI

public struct SettingsPoliciesSection: View {
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault

  public init() {}

  public var body: some View {
    Form {
      Section {
        Toggle("Show edge legend", isOn: $edgeLegendVisible)
          .accessibilityHint(
            "Shows or hides the edge legend card in Policy Canvas windows"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesEdgeLegendToggle
          )
      } header: {
        Text("Policies")
      } footer: {
        Text(
          """
          Controls Policy Canvas reference chrome. When edge legend is disabled,
          the legend card is removed entirely from the canvas.
          """
        )
      }
    }
    .settingsDetailFormStyle()
  }
}
