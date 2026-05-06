import HarnessMonitorKit
import SwiftUI

#Preview("Preferences MCP") {
  PreferencesMCPSection(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded))
    .frame(width: 520, height: 260)
}
