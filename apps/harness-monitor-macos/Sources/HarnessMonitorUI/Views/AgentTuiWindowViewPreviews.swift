import HarnessMonitorKit
import SwiftUI

#Preview("Agent TUI - Create") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .ready
    )
  )
}

#Preview("Agent TUI - Create With Recovery") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .excluded
    )
  )
}

#Preview("Agent TUI - Running Session") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.runningSingle,
      selectedTuiID: AgentTuiPreviewSupport.runningSingle.first?.tuiId
    )
  )
}

#Preview("Agent TUI - Stopped Session") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.stoppedSingle,
      selectedTuiID: AgentTuiPreviewSupport.stoppedSingle.first?.tuiId
    )
  )
}

#Preview("Agent TUI - Multiple Sessions") {
  agentTuiWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: Array(AgentTuiPreviewSupport.overflowMixed.prefix(3)),
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[1].tuiId
    )
  )
}

#Preview("Agent TUI - Many Sessions") {
  agentTuiWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[4].tuiId
    )
  )
}

#Preview("Agent TUI - Mixed Sessions") {
  agentTuiWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[5].tuiId
    )
  )
}

@MainActor
private func agentTuiWindowPreview(
  width: CGFloat = 980,
  height: CGFloat = 660,
  store: HarnessMonitorStore
) -> some View {
  AgentTuiWindowView(store: store)
    .frame(width: width, height: height)
    .padding()
}
