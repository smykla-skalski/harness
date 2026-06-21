import SwiftUI

#Preview("Policy canvas decision matrix") {
  PolicyCanvasDecisionMatrixView(
    rows: [
      PolicyCanvasDecisionMatrixRowModel(
        id: "scenario-merge.merge_pr",
        scenarioName: "Merge - checks green",
        actionRaw: "merge_pr",
        actionTitle: "Merge PR",
        verdict: .allow,
        reasonCode: "default_allow",
        visitedNodeIds: ["n1"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        id: "scenario-mutate.mutate_repo",
        scenarioName: "Mutate repo",
        actionRaw: "mutate_repo",
        actionTitle: "Mutate repo",
        verdict: .dryRun,
        reasonCode: "dry_run_required",
        visitedNodeIds: ["n2"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        id: "scenario-secret.access_secret",
        scenarioName: "Access secret",
        actionRaw: "access_secret",
        actionTitle: "Access secret",
        verdict: .deny,
        reasonCode: "checks_not_green",
        visitedNodeIds: ["n3"]
      ),
      PolicyCanvasDecisionMatrixRowModel(
        id: "scenario-agent.spawn_agent",
        scenarioName: "Spawn agent",
        actionRaw: "spawn_agent",
        actionTitle: "Spawn agent",
        verdict: .needsHuman,
        reasonCode: "human_required",
        visitedNodeIds: []
      ),
    ],
    isEvaluating: false,
    focusDecision: { _ in }
  )
  .frame(width: 380)
  .padding(24)
}
