import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas corridor bundle sub-lane")
struct PolicyCanvasCorridorBundleSubLaneTests {
  @Test("two edges sharing source group, target group, and target node get distinct horizontalLaneY")
  func bundledEdgesGetDistinctHorizontalLaneY() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source-a",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "source-b",
          groupID: "left",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "target",
          groupID: "right",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(
          id: "e1",
          sourceNodeID: "source-a",
          targetNodeID: "target"
        ),
        PolicyCanvasLayoutEdge(
          id: "e2",
          sourceNodeID: "source-b",
          targetNodeID: "target"
        ),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "left",
          originalIndex: 0,
          memberNodeIDs: ["source-a", "source-b"]
        ),
        PolicyCanvasLayoutGroup(
          id: "right",
          originalIndex: 1,
          memberNodeIDs: ["target"]
        ),
      ]
    )

    guard
      let result = PolicyCanvasLayeredLayoutEngine(mode: .initialLoad).layout(graph: graph),
      let hints = result.routingHints,
      let h1 = hints.edgeHint(for: "e1"),
      let h2 = hints.edgeHint(for: "e2")
    else {
      Issue.record("Expected routing hints for bundled edges")
      return
    }

    #expect(
      h1.horizontalLaneY != h2.horizontalLaneY,
      "Bundle rails must differ: h1=\(h1.horizontalLaneY) h2=\(h2.horizontalLaneY)"
    )
  }

  @Test("four edges sharing source group, target group, and target node spread across four distinct Y rails")
  func fourBundledEdgesSpreadAcrossFourRails() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "src-1",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "src-2",
          groupID: "left",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "src-3",
          groupID: "left",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "src-4",
          groupID: "left",
          originalIndex: 3,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "sink",
          groupID: "right",
          originalIndex: 4,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "e1", sourceNodeID: "src-1", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "e2", sourceNodeID: "src-2", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "e3", sourceNodeID: "src-3", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "e4", sourceNodeID: "src-4", targetNodeID: "sink"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "left",
          originalIndex: 0,
          memberNodeIDs: ["src-1", "src-2", "src-3", "src-4"]
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
      Issue.record("Expected routing hints for four-edge bundle")
      return
    }

    let ys = ["e1", "e2", "e3", "e4"].compactMap { hints.edgeHint(for: $0)?.horizontalLaneY }
    #expect(ys.count == 4)
    #expect(Set(ys).count == 4, "Four bundled edges must have four distinct horizontalLaneY rails, got \(ys)")
  }

  @Test("bundle ordinal is stable across runs for the same edge id ordering")
  func bundleOrdinalIsStable() {
    let graph = PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "src-a",
          groupID: "left",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "src-b",
          groupID: "left",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "sink",
          groupID: "right",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "stable-a", sourceNodeID: "src-a", targetNodeID: "sink"),
        PolicyCanvasLayoutEdge(id: "stable-b", sourceNodeID: "src-b", targetNodeID: "sink"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "left",
          originalIndex: 0,
          memberNodeIDs: ["src-a", "src-b"]
        ),
        PolicyCanvasLayoutGroup(
          id: "right",
          originalIndex: 1,
          memberNodeIDs: ["sink"]
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
      let h1a = firstRun.edgeHint(for: "stable-a"),
      let h1b = firstRun.edgeHint(for: "stable-b"),
      let h2a = secondRun.edgeHint(for: "stable-a"),
      let h2b = secondRun.edgeHint(for: "stable-b")
    else {
      Issue.record("Expected routing hints for stability test")
      return
    }

    #expect(h1a.horizontalLaneY == h2a.horizontalLaneY)
    #expect(h1b.horizontalLaneY == h2b.horizontalLaneY)
  }
}
