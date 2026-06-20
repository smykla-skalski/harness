import SwiftUI

private let sampleScenarioRows: [PolicyCanvasScenarioRowModel] = [
  PolicyCanvasScenarioRowModel(
    id: "s1",
    name: "Merge - checks green",
    actionTitle: "merge pr",
    verdict: .allow,
    reasonCode: "default_allow",
    visitedNodeIds: ["n1"]
  ),
  PolicyCanvasScenarioRowModel(
    id: "s2",
    name: "Access secret - risky",
    actionTitle: "access secret",
    verdict: .deny,
    reasonCode: "checks_not_green",
    visitedNodeIds: ["n2"]
  ),
  PolicyCanvasScenarioRowModel(
    id: "s3",
    name: "Spawn agent",
    actionTitle: "spawn agent",
    verdict: .needsHuman,
    reasonCode: "human_required",
    visitedNodeIds: []
  ),
]

#Preview("Policy canvas scenario inspector") {
  PolicyCanvasScenarioInspector(
    rows: sampleScenarioRows,
    isEvaluating: false,
    focusDecision: { _ in },
    deleteScenario: { _ in },
    resetScenarios: {}
  )
  .frame(width: 380)
  .padding(24)
}

#Preview("Policy canvas scenario rows") {
  VStack(spacing: 0) {
    ForEach(sampleScenarioRows) { row in
      PolicyCanvasScenarioRow(row: row, focusDecision: { _ in }, deleteScenario: { _ in })
    }
  }
  .frame(width: 380)
  .padding(24)
}
