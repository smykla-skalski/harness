import SwiftUI

private let sampleReplayRows: [PolicyCanvasReplayRowModel] = [
  PolicyCanvasReplayRowModel(
    id: "d1",
    actionTitle: "merge pr",
    recordedAt: "2026-06-20T10:00:00Z",
    historicalVerdict: .allow,
    draftVerdict: .deny,
    changed: true,
    insufficientEvidence: false,
    visitedNodeIds: ["n1"]
  ),
  PolicyCanvasReplayRowModel(
    id: "d2",
    actionTitle: "spawn agent",
    recordedAt: "2026-06-20T09:30:00Z",
    historicalVerdict: .needsHuman,
    draftVerdict: .needsHuman,
    changed: false,
    insufficientEvidence: false,
    visitedNodeIds: ["n2"]
  ),
  PolicyCanvasReplayRowModel(
    id: "d3",
    actionTitle: "access secret",
    recordedAt: "2026-06-20T09:00:00Z",
    historicalVerdict: .allow,
    draftVerdict: .deny,
    changed: false,
    insufficientEvidence: true,
    visitedNodeIds: []
  ),
]

#Preview("Policy canvas replay inspector") {
  PolicyCanvasReplayInspector(
    rows: sampleReplayRows,
    summary: PolicyCanvasReplaySummary(sampleSize: 3, changedCount: 1),
    isLoading: false,
    isStale: false,
    focusDecision: { _ in },
    loadReplay: {}
  )
  .frame(width: 380)
  .padding(24)
}

#Preview("Policy canvas replay inspector - stale") {
  PolicyCanvasReplayInspector(
    rows: sampleReplayRows,
    summary: PolicyCanvasReplaySummary(sampleSize: 3, changedCount: 1),
    isLoading: false,
    isStale: true,
    focusDecision: { _ in },
    loadReplay: {}
  )
  .frame(width: 380)
  .padding(24)
}

#Preview("Policy canvas replay rows") {
  VStack(spacing: 0) {
    ForEach(sampleReplayRows) { row in
      PolicyCanvasReplayRow(row: row, focusDecision: { _ in })
    }
  }
  .frame(width: 380)
  .padding(24)
}
