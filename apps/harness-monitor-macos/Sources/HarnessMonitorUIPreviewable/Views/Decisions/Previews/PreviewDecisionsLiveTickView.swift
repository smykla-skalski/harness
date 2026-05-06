import HarnessMonitorKit
import SwiftUI

#Preview("Decisions Live Tick — empty") {
  DecisionsLiveTickView()
    .frame(width: 420, height: 100)
}

#Preview("Decisions Live Tick — populated") {
  DecisionsLiveTickView(
    snapshot: DecisionLiveTickSnapshot(
      lastSnapshotID: "snap-2026-04-23T09:14:00Z",
      tickLatencyP50Ms: 128,
      tickLatencyP95Ms: 342,
      activeObserverCount: 4,
      quarantinedRuleIDs: ["stuck-agent", "task-starvation"]
    )
  )
  .frame(width: 420, height: 160)
}
