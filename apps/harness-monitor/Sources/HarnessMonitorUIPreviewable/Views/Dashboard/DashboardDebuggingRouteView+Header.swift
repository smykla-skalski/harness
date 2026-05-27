import SwiftUI

extension DashboardDebuggingRouteView {
  var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Label("Debugging", systemImage: DashboardWindowRoute.debugging.systemImage)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
      Text("Scratch space for local Monitor experiments")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}
