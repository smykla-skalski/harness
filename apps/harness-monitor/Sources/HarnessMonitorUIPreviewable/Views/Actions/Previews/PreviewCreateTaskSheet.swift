import HarnessMonitorKit
import SwiftUI

#Preview("Create task sheet") {
  CreateTaskSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId
  )
  .frame(width: 480, height: 560)
}
