import HarnessMonitorKit
import SwiftUI

#Preview("Workspace Toolbar Button — empty") {
  WorkspaceToolbarButton(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    slice: SupervisorToolbarSlice()
  )
  .padding()
}
