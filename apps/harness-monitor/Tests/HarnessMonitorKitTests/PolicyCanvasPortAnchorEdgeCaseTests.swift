import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Wave 3M P50 follow-up: locks anchor freshness when the underlying node
/// changes shape (moved, deleted). Sibling to wave 1C's PolicyCanvasAnchorTests
/// which covers nil-on-missing and basic geometry — this file adds the
/// stale-anchor coverage.
@Suite("Policy canvas port anchor — freshness")
@MainActor
struct PolicyCanvasPortAnchorEdgeCaseTests {
  @Test("output port anchor shifts with the node after a drag")
  func outputAnchorShiftsAfterNodeMove() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score node")
      return
    }
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: "output-fail",
      kind: .output
    )
    guard let before = viewModel.portAnchor(for: endpoint) else {
      Issue.record("expected initial anchor")
      return
    }

    viewModel.dragNode(node.id, translation: CGSize(width: 80, height: 0))
    viewModel.endNodeDrag(node.id, translation: CGSize(width: 80, height: 0))
    guard
      let moved = viewModel.node(node.id),
      let after = viewModel.portAnchor(for: endpoint)
    else {
      Issue.record("expected anchor after drag")
      return
    }

    // The anchor follows the node's new position; no cache staleness.
    #expect(after.x == moved.position.x + PolicyCanvasLayout.nodeSize.width)
    #expect(after.x > before.x)
  }

  @Test("input port anchor shifts with the node after a vertical drag")
  func inputAnchorShiftsVerticallyAfterNodeMove() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "risk-score",
      portID: "input-event",
      kind: .input
    )
    guard let before = viewModel.portAnchor(for: endpoint) else {
      Issue.record("expected initial anchor")
      return
    }

    viewModel.dragNode("risk-score", translation: CGSize(width: 0, height: 60))
    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 0, height: 60))
    guard let after = viewModel.portAnchor(for: endpoint) else {
      Issue.record("expected anchor after drag")
      return
    }

    #expect(after.x == before.x)
    #expect(after.y > before.y)
  }

  @Test("anchor returns nil after the node is deleted")
  func anchorNilAfterNodeDelete() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "risk-score",
      portID: "input-event",
      kind: .input
    )
    #expect(viewModel.portAnchor(for: endpoint) != nil)

    viewModel.deleteNode("risk-score")

    #expect(viewModel.portAnchor(for: endpoint) == nil)
  }

  @Test("anchor on edge endpoint becomes nil after that endpoint's node is deleted")
  func edgeEndpointAnchorNilAfterEndpointNodeDelete() {
    let viewModel = PolicyCanvasViewModel.sample()
    let edge = viewModel.edges.first { $0.id == "edge-intake-risk" }
    guard let edge else {
      Issue.record("expected edge-intake-risk in sample")
      return
    }
    #expect(viewModel.portAnchor(for: edge.source) != nil)

    viewModel.deleteNode(edge.source.nodeID)

    #expect(viewModel.portAnchor(for: edge.source) == nil)
    // The edge itself is pruned by deleteNode, so the target endpoint anchor
    // is the relevant survivor — that anchor is still resolvable since the
    // target node remains.
    #expect(viewModel.portAnchor(for: edge.target) != nil)
  }

  @Test("anchor stays valid when an unrelated node is deleted")
  func anchorSurvivesUnrelatedNodeDelete() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: "risk-score",
      portID: "input-event",
      kind: .input
    )
    guard let before = viewModel.portAnchor(for: endpoint) else {
      Issue.record("expected initial anchor")
      return
    }

    viewModel.deleteNode("promote-release")

    let after = viewModel.portAnchor(for: endpoint)
    #expect(after == before)
  }
}
