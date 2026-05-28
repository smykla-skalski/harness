import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas corridor bundle assignment")
struct PolicyCanvasCorridorBundleAssignmentTests {
  @Test("four edges sharing source and target node receive one shared bus Y")
  func sameTargetBundleSharesBusY() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "sink",
          groupID: "right",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "fail-1", sourceNodeID: "source", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "fail-2", sourceNodeID: "source", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "fail-3", sourceNodeID: "source", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "fail-4", sourceNodeID: "source", targetNodeID: "sink"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "left",
          originalIndex: 0,
          memberNodeIDs: ["source"]
        ),
        PolicyCanvasLayoutGroup(
          id: "right",
          originalIndex: 1,
          memberNodeIDs: ["sink"]
        ),
      ]
    )

    guard
      let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph),
      let hints = result.routingHints
    else {
      Issue.record("Expected routing hints for same-target bundle")
      return
    }

    let ys = ["fail-1", "fail-2", "fail-3", "fail-4"].compactMap {
      hints.edgeHint(for: $0)?.horizontalLaneY
    }
    #expect(ys.count == 4)
    #expect(
      Set(ys).count == 1,
      "Four edges to one target share one bus Y, got distinct values \(Set(ys))"
    )
  }

  @Test("bundle hints are deterministic across repeated runs")
  func bundleHintsAreStable() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "src",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "sink-a",
          groupID: "right",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "sink-b",
          groupID: "right",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "edge-a", sourceNodeID: "src", targetNodeID: "sink-a"),
        PolicyCanvasLayoutEdge(id: "edge-b", sourceNodeID: "src", targetNodeID: "sink-b"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "left",
          originalIndex: 0,
          memberNodeIDs: ["src"]
        ),
        PolicyCanvasLayoutGroup(
          id: "right",
          originalIndex: 1,
          memberNodeIDs: ["sink-a", "sink-b"]
        ),
      ]
    )

    let firstRun = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)?
      .routingHints
    let secondRun = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph)?
      .routingHints

    guard
      let firstRun,
      let secondRun,
      let h1a = firstRun.edgeHint(for: "edge-a"),
      let h1b = firstRun.edgeHint(for: "edge-b"),
      let h2a = secondRun.edgeHint(for: "edge-a"),
      let h2b = secondRun.edgeHint(for: "edge-b")
    else {
      Issue.record("Expected routing hints for stability test")
      return
    }

    #expect(h1a == h2a)
    #expect(h1b == h2b)
  }

  @Test("corridor bundle tiebreak orders by source anchor Y first")
  func corridorBundleTiebreakOrdersBySourceY() {
    let upperFirst = policyCanvasCorridorBundleTiebreak(
      sourceAnchor: CGPoint(x: 100, y: 100),
      targetAnchor: CGPoint(x: 500, y: 200),
      sourceNodeID: "z-src",
      targetNodeID: "z-tgt",
      edgeID: "z-edge"
    )
    let lowerSecond = policyCanvasCorridorBundleTiebreak(
      sourceAnchor: CGPoint(x: 100, y: 300),
      targetAnchor: CGPoint(x: 500, y: 200),
      sourceNodeID: "a-src",
      targetNodeID: "a-tgt",
      edgeID: "a-edge"
    )

    #expect(upperFirst < lowerSecond)
  }

  @Test("corridor bundle tiebreak falls back to edge id only when geometry ties")
  func corridorBundleTiebreakFallsBackToEdgeID() {
    let earlier = policyCanvasCorridorBundleTiebreak(
      sourceAnchor: CGPoint(x: 100, y: 100),
      targetAnchor: CGPoint(x: 500, y: 200),
      sourceNodeID: "src",
      targetNodeID: "tgt",
      edgeID: "alpha"
    )
    let later = policyCanvasCorridorBundleTiebreak(
      sourceAnchor: CGPoint(x: 100, y: 100),
      targetAnchor: CGPoint(x: 500, y: 200),
      sourceNodeID: "src",
      targetNodeID: "tgt",
      edgeID: "beta"
    )

    #expect(earlier < later)
  }
}
