import HarnessMonitorKit
import SwiftUI

#Preview("Workspace Toolbar Button — empty") {
  SessionAttentionToolbarButton(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    slice: SupervisorToolbarSlice()
  )
  .padding()
}
