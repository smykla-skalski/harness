import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas accessibility")
@MainActor
struct PolicyCanvasAccessibilityTests {
  @Test("node accessibility label is composed from kind and title")
  func nodeAccessibilityLabelIsComposedFromTitle() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("policy-source") else {
      Issue.record("expected policy-source sample node")
      return
    }

    let label = viewModel.accessibilityLabel(for: node)

    #expect(label == "Source Policy intake")
  }

  @Test("node accessibility value lists outgoing connections")
  func nodeAccessibilityValueListsConnectedNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let node = viewModel.node("risk-score") else {
      Issue.record("expected risk-score sample node")
      return
    }

    let value = viewModel.accessibilityValue(for: node)

    #expect(value.contains("Context map"))
    #expect(value.contains("Review gate"))
    #expect(value.contains("group Evaluation"))
  }

  @Test("edge accessibility label includes source and target context")
  func edgeAccessibilityLabelIncludesSourceAndTargetContext() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let edge = viewModel.edges.first(where: { $0.id == "edge-intake-risk" }) else {
      Issue.record("expected edge-intake-risk sample edge")
      return
    }

    let label = viewModel.accessibilityLabel(for: edge)

    #expect(label == "Edge normalize, from Policy intake event to Risk score event")
  }

  @Test("port diameter meets the accessibility hit-test floor")
  func portDiameterMeetsAccessibilityFloor() {
    #expect(PolicyCanvasLayout.portDiameter >= 18)
    #expect(PolicyCanvasLayout.portHitTestExtension >= 8)
  }

  // P27 focus order: visual top-to-bottom, then left-to-right within the
  // same row (10pt y-axis tolerance). The sample fixture has Source at
  // (120,140), Risk at (360,112), Context at (580,86), Review at (590,220),
  // Promote at (900,160) — so Context (y=86) lands first, then Risk
  // (y=112), then Source (y=140), then Promote (y=160), then Review (y=220).
  @Test("focus-order visits nodes top-to-bottom then left-to-right")
  func focusOrderVisitsNodesInVisualOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    let order = viewModel.accessibilityNodeFocusOrder()
    #expect(
      order == [
        "context-map",
        "risk-score",
        "policy-source",
        "promote-release",
        "review-gate",
      ]
    )
  }

  // P27 row-tolerance: two nodes within ~10pt of the same y should sort by
  // x first, not y. We move a clone-ish synthetic offset of risk-score into
  // a band that ties with another and assert x ordering wins.
  @Test("focus-order ties within a 10pt row are broken by x")
  func focusOrderTiesBreakByX() {
    let viewModel = PolicyCanvasViewModel.sample()
    // policy-source y=140, risk-score y=112 — 28pt apart so they keep their
    // y order. Move risk into the same row as source (delta -28 -> y 140).
    guard let risk = viewModel.node("risk-score") else {
      Issue.record("expected risk-score sample node")
      return
    }
    viewModel.dragNode("risk-score", translation: CGSize(width: 0, height: 28))
    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 0, height: 28))
    let order = viewModel.accessibilityNodeFocusOrder()
    let policyIndex = order.firstIndex(of: "policy-source") ?? -1
    let riskIndex = order.firstIndex(of: "risk-score") ?? -1
    #expect(policyIndex >= 0)
    #expect(riskIndex >= 0)
    // policy-source x=120 < risk x=360, so policy ranks first within the row.
    #expect(policyIndex < riskIndex)
    _ = risk
  }

  // P28 actions: a fresh palette node has duplicate/delete/connect surface,
  // and the duplicate clone is shifted by the configured 20pt offset on
  // both axes (after grid snap).
  @Test("duplicate node clones structure and offsets position")
  func duplicateNodeClonesStructureAndOffsetsPosition() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let original = viewModel.node("policy-source") else {
      Issue.record("expected policy-source sample node")
      return
    }
    let beforeCount = viewModel.nodes.count
    let cloneID = viewModel.duplicateNode("policy-source")
    #expect(cloneID != nil)
    #expect(viewModel.nodes.count == beforeCount + 1)
    guard let id = cloneID, let clone = viewModel.node(id) else {
      Issue.record("expected duplicate clone to exist")
      return
    }
    #expect(clone.kind == original.kind)
    #expect(clone.groupID == original.groupID)
    // After snap-to-grid the offset is at least the configured 20pt step.
    #expect(clone.position.x >= original.position.x + 20)
    #expect(clone.position.y >= original.position.y + 20)
    #expect(viewModel.documentDirty)
    #expect(viewModel.selection == .node(id))
  }

  // P28 connect-to-first-target: the helper enumerates reachable inputs and
  // wires the first one through the existing drop pipeline, preserving the
  // edge-creation invariants (no self-edges, no duplicates).
  @Test("accessibility connect routes through the drop pipeline")
  func accessibilityConnectRoutesThroughDropPipeline() {
    let viewModel = PolicyCanvasViewModel.sample()
    let beforeEdges = viewModel.edges.count
    let targets = viewModel.accessibilityConnectableTargets(fromNodeID: "policy-source")
    #expect(!targets.isEmpty)
    guard let first = targets.first else {
      Issue.record("expected at least one connectable target")
      return
    }
    let connected = viewModel.accessibilityConnect(
      fromNodeID: "policy-source",
      to: first
    )
    #expect(connected)
    #expect(viewModel.edges.count == beforeEdges + 1)
  }

  // P28 open inspector: raises the draft tab + selects the node so the
  // inspector form is the active surface.
  @Test("accessibility open inspector selects node and raises draft tab")
  func accessibilityOpenInspectorSelectsAndRaisesTab() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.selectedTab = .simulation
    viewModel.accessibilityOpenInspector(forNodeID: "promote-release")
    #expect(viewModel.selectedTab == .draft)
    #expect(viewModel.selection == .node("promote-release"))
  }
}
