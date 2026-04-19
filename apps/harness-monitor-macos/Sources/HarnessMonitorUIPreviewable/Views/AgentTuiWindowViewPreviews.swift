import HarnessMonitorKit
import SwiftUI

#Preview("Agents - Create") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .ready
    )
  )
}

#Preview("Agents - Create With Recovery") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: [],
      bridgeState: .excluded
    )
  )
}

#Preview("Agents - Running Session") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.runningSingle,
      selectedTuiID: AgentTuiPreviewSupport.runningSingle.first?.tuiId
    )
  )
}

#Preview("Agents - Stopped Session") {
  agentTuiWindowPreview(
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.stoppedSingle,
      selectedTuiID: AgentTuiPreviewSupport.stoppedSingle.first?.tuiId
    )
  )
}

#Preview("Agents - Multiple Sessions") {
  agentTuiWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: Array(AgentTuiPreviewSupport.overflowMixed.prefix(3)),
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[1].tuiId
    )
  )
}

#Preview("Agents - Many Sessions") {
  agentTuiWindowPreview(
    width: 980,
    store: AgentTuiPreviewSupport.makeStore(
      tuis: AgentTuiPreviewSupport.overflowMixed,
      selectedTuiID: AgentTuiPreviewSupport.overflowMixed[4].tuiId
    )
  )
}

#Preview("Agents - Mixed Sessions") {
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
