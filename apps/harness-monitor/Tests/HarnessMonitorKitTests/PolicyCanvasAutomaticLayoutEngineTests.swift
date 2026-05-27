import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas automatic layout engine")
struct PolicyCanvasAutomaticLayoutEngineTests {
  @Test("layered engine metrics do not worsen crossing pressure on a two-rank graph")
  func layeredEngineTracksCrossingPressure() {
    let graph = crossingReductionGraph()
    let naiveMetrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "a": CGPoint(x: 72, y: 72),
        "b": CGPoint(x: 72, y: 332),
        "c": CGPoint(x: 532, y: 72),
        "d": CGPoint(x: 532, y: 332),
      ],
      groupRanks: [
        "a": 0,
        "b": 0,
        "c": 1,
        "d": 1,
      ],
      layoutGroupIDByNodeID: [
        "a": "a",
        "b": "b",
        "c": "c",
        "d": "d",
      ]
    )
    let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)

    #expect(naiveMetrics.edgeCrossingCount == 1)
    guard let result else {
      Issue.record("Expected a layout result for the crossing-reduction graph")
      return
    }
    #expect(result.metrics.edgeCrossingCount <= naiveMetrics.edgeCrossingCount)
    #expect(result.metrics.flowDirectionViolationCount == 0)
    #expect(result.metrics.readabilityScore > 0)
  }

  @Test("metrics capture backward flow violations")
  func metricsCaptureBackwardFlowViolations() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "left",
          groupID: nil,
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "right",
          groupID: nil,
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "back-edge", sourceNodeID: "left", targetNodeID: "right")
      ],
      groups: []
    )
    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: [
        "left": CGPoint(x: 420, y: 72),
        "right": CGPoint(x: 72, y: 72),
      ],
      groupRanks: [
        "left": 0,
        "right": 1,
      ],
      layoutGroupIDByNodeID: [
        "left": "left",
        "right": "right",
      ]
    )

    #expect(metrics.flowDirectionViolationCount == 1)
    #expect(metrics.readabilityScore < 1_000)
  }

  private func crossingReductionGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "a",
          groupID: "main",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "b",
          groupID: "main",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "c",
          groupID: "main",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "d",
          groupID: "main",
          originalIndex: 3,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "main",
          originalIndex: 0,
          memberNodeIDs: ["a", "b", "c", "d"]
        )
      ]
    )
  }
}
