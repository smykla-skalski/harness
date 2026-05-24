import HarnessMonitorKit
import SwiftUI

struct AcpRuntimeView: View {
  let store: HarnessMonitorStore
  let runtimeState: AcpAgentRuntimeState
  let inspectStatus: AcpRuntimeInspectStatus
  let presentation: AcpRuntimePresentation

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      AcpRuntimeStatusStrip(
        store: store,
        runtimeState: runtimeState,
        inspectStatus: inspectStatus,
        presentation: presentation
      )
      if presentation == .full {
        AcpRuntimeDisclosure(runtimeState: runtimeState, inspectStatus: inspectStatus)
      }
    }
  }
}
