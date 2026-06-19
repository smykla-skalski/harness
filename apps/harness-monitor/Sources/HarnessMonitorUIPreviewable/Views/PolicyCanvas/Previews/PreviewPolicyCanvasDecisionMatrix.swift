import SwiftUI

#Preview("Policy canvas decision matrix") {
  PolicyCanvasDecisionMatrixView(
    rows: [
      PolicyCanvasDecisionMatrixRowModel(
        actionRaw: "merge_pr",
        actionTitle: "merge pr",
        verdict: .allow,
        reasonCode: "default_allow",
        visitedNodeIds: ["n1"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        actionRaw: "mutate_repo",
        actionTitle: "mutate repo",
        verdict: .dryRun,
        reasonCode: "dry_run_required",
        visitedNodeIds: ["n2"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        actionRaw: "access_secret",
        actionTitle: "access secret",
        verdict: .deny,
        reasonCode: "checks_not_green",
        visitedNodeIds: ["n3"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        actionRaw: "spawn_agent",
        actionTitle: "spawn agent",
        verdict: .needsHuman,
        reasonCode: "human_required",
        visitedNodeIds: []
      ),
    ],
    focusDecision: { _ in }
  )
  .frame(width: 380)
  .padding(24)
}
