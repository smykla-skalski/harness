import HarnessMonitorKit
import SwiftUI

#Preview("Settings MCP") {
  SettingsMCPSection(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded))
    .frame(width: 520, height: 260)
}
