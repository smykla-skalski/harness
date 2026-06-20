import HarnessMonitorPolicyModels
import SwiftUI

private func sampleEntry(
  name: String,
  action: PolicyAction,
  live: PolicyDecision?,
  draft: PolicyDecision,
  changed: Bool
) -> PolicyPipelineGoLiveDiffEntry {
  PolicyPipelineGoLiveDiffEntry(
    scenarioId: name,
    scenarioName: name,
    action: action,
    liveDecision: live,
    draftDecision: draft,
    changed: changed
  )
}

#Preview("Go-live diff - changed") {
  PolicyCanvasGoLiveDiffView(
    diff: PolicyPipelineGoLiveDiff(
      hasLivePolicy: true,
      changedCount: 2,
      diffs: [
        sampleEntry(
          name: "Merge - checks green",
          action: .mergePr,
          live: .allow(reasonCode: .autoMergeAllowed, policyVersion: "v1"),
          draft: .requireHuman(reasonCode: .humanRequired, policyVersion: "v2"),
          changed: true
        ),
        sampleEntry(
          name: "Access secret",
          action: .accessSecret,
          live: .deny(reasonCode: .checksNotGreen, policyVersion: "v1"),
          draft: .dryRunOnly(reasonCode: .dryRunRequired, policyVersion: "v2"),
          changed: true
        ),
        sampleEntry(
          name: "Sync",
          action: .sync,
          live: .allow(reasonCode: .defaultAllow, policyVersion: "v1"),
          draft: .allow(reasonCode: .defaultAllow, policyVersion: "v2"),
          changed: false
        ),
      ]
    ),
    isLoading: false
  )
  .frame(width: 420)
  .padding(24)
}

#Preview("Go-live diff - parity") {
  PolicyCanvasGoLiveDiffView(
    diff: PolicyPipelineGoLiveDiff(hasLivePolicy: true, changedCount: 0, diffs: []),
    isLoading: false
  )
  .frame(width: 420)
  .padding(24)
}

#Preview("Go-live diff - no live policy") {
  PolicyCanvasGoLiveDiffView(
    diff: PolicyPipelineGoLiveDiff(hasLivePolicy: false, changedCount: 0, diffs: []),
    isLoading: false
  )
  .frame(width: 420)
  .padding(24)
}

#Preview("Go-live diff - loading") {
  PolicyCanvasGoLiveDiffView(diff: nil, isLoading: true)
    .frame(width: 420)
    .padding(24)
}
