import HarnessMonitorPolicyModels
import SwiftUI

#Preview("Go-live sheet") {
  PolicyCanvasGoLiveSheet(
    viewModel: .sample(),
    liveStatus: .draft(liveRevision: 6),
    loadDiff: {
      PolicyPipelineGoLiveDiff(
        hasLivePolicy: true,
        changedCount: 1,
        diffs: [
          PolicyPipelineGoLiveDiffEntry(
            scenarioId: "s1",
            scenarioName: "Merge - checks green",
            action: .mergePr,
            liveDecision: .allow(reasonCode: .autoMergeAllowed, policyVersion: "v1"),
            draftDecision: .requireHuman(reasonCode: .humanRequired, policyVersion: "v2"),
            changed: true
          )
        ]
      )
    },
    confirm: {},
    dismiss: {}
  )
}
