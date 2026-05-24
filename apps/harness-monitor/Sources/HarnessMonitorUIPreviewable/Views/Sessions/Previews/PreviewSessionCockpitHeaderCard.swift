import HarnessMonitorKit
import SwiftUI

#Preview("Cockpit header") {
  SessionCockpitHeaderCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    observeSelectedSession: {},
    requestEndSessionConfirmation: {},
    inspectObserver: {}
  )
  .padding()
  .frame(width: 960)
}
