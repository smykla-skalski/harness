import HarnessMonitorKit
import SwiftUI

#Preview("Leader transfer sheet") {
  LeaderTransferSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId
  )
  .frame(width: 460, height: 540)
}
