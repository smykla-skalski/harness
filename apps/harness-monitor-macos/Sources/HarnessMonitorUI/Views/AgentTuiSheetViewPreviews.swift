import HarnessMonitorKit
import SwiftUI

#Preview("Agent TUI - Create") {
  agentTuiSheetPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .ready
    )
  )
}

#Preview("Agent TUI - Create With Recovery") {
  agentTuiSheetPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .excluded
    )
  )
}

#Preview("Agent TUI - Running Session") {
  agentTuiSheetPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.runningSingle,
      selectedTuiID: AgentTuiPreviewSupport.runningSingle.first?.tuiId
    )
  )
}

#Preview("Agent TUI - Stopped Session") {
  agentTuiSheetPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.stoppedSingle,
      selectedTuiID: AgentTuiPreviewSupport.stoppedSingle.first?.tuiId
    )
  )
}

#Preview("Agent TUI - Multiple Sessions") {
  agentTuiSheetPreview(
    width: 940,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: Array(AgentTuiPreviewSupport.overflowMixed.prefix(3)),
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[1].tuiId
    )
  )
}

#Preview("Agent TUI - Overflow") {
  agentTuiSheetPreview(
    width: 760,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[4].tuiId
    )
  )
}

#Preview("Agent TUI - Mixed Sessions") {
  agentTuiSheetPreview(
    width: 820,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[5].tuiId
    )
  )
}

@MainActor
private func agentTuiSheetPreview(
  width: CGFloat = 920,
  height: CGFloat = 660,
  store: HarnessMonitorStore
) -> some View {
  AgentTuiSheetView(store: store)
    .frame(width: width, height: height)
    .padding()
}
