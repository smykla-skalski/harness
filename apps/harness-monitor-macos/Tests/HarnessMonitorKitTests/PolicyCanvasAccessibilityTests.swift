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

    #expect(label == "normalize edge, from Policy intake event to Risk score event")
  }

  // Watson's WCAG 1.4.1 concern: the new kind palette (cyan/purple/red) is
  // a color-only signal unless VoiceOver also surfaces it. The value must
  // name the kind and an active suffix when the edge is animating.
  @Test("edge accessibility value names the kind word")
  func edgeAccessibilityValueNamesKind() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(nodeID: "n", portID: "p", kind: .output)
    let target = PolicyCanvasPortEndpoint(nodeID: "n2", portID: "p2", kind: .input)
    let flow = PolicyCanvasEdge(id: "e1", source: endpoint, target: target, label: "")
    let denied = PolicyCanvasEdge(
      id: "e2",
      source: endpoint,
      target: target,
      label: "",
      condition: "denied"
    )
    let conditional = PolicyCanvasEdge(
      id: "e3",
      source: endpoint,
      target: target,
      label: "",
      condition: "manual_approval_required"
    )
    #expect(viewModel.accessibilityValue(for: flow) == "flow")
    #expect(viewModel.accessibilityValue(for: denied) == "error")
    #expect(viewModel.accessibilityValue(for: conditional) == "control")
  }

  @Test("edge accessibility value adds 'active' suffix when animating")
  func edgeAccessibilityValueAddsActiveSuffix() {
    let viewModel = PolicyCanvasViewModel.sample()
    let endpoint = PolicyCanvasPortEndpoint(nodeID: "n", portID: "p", kind: .output)
    let target = PolicyCanvasPortEndpoint(nodeID: "n2", portID: "p2", kind: .input)
    let staticEdge = PolicyCanvasEdge(id: "s", source: endpoint, target: target, label: "")
    let liveEdge = PolicyCanvasEdge(
      id: "l",
      source: endpoint,
      target: target,
      label: "",
      isAnimated: true
    )
    #expect(viewModel.accessibilityValue(for: staticEdge, isAnimating: false) == "flow")
    #expect(viewModel.accessibilityValue(for: liveEdge, isAnimating: true) == "flow, active")
    // Reduce-motion gate at the call site flips `isAnimating` false; the
    // value drops the "active" suffix so the AT user has an accurate model
    // of edge state.
    #expect(viewModel.accessibilityValue(for: liveEdge, isAnimating: false) == "flow")
  }

  @Test("kind dash pattern is non-empty for control and error")
  func kindDashPatternEncodesKindWithoutColor() {
    // Watson + WCAG 1.4.1: color cannot be the only signal. The dash
    // pattern gives users with color-vision deficiencies a non-color
    // signifier of kind.
    #expect(PolicyCanvasEdgeKind.flow.strokeDashPattern.isEmpty)
    #expect(!PolicyCanvasEdgeKind.control.strokeDashPattern.isEmpty)
    #expect(!PolicyCanvasEdgeKind.error.strokeDashPattern.isEmpty)
    // Patterns must be distinct so control and error read as different
    // stroke shapes, not just different colors.
    #expect(
      PolicyCanvasEdgeKind.control.strokeDashPattern
        != PolicyCanvasEdgeKind.error.strokeDashPattern
    )
  }

  @Test("port diameter meets the accessibility hit-test floor")
  func portDiameterMeetsAccessibilityFloor() {
    #expect(PolicyCanvasLayout.portDiameter >= 18)
    #expect(PolicyCanvasLayout.portHitTestExtension >= 8)
  }

  // Phase 3 (Watson R2): the default accessibility activation point on a
  // SwiftUI accessibility element is the geometric frame center, which sits
  // in empty canvas for L-shaped or zig-zag routes. The arc-length midpoint
  // is always on the stroke - VoiceOver and keyboard focus then activate on
  // a point a sighted user would also click.
  @Test("arc-length midpoint of a straight segment is its center")
  func arcLengthMidpointOfStraightSegment() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: .zero
    )
    #expect(route.arcLengthMidpoint == CGPoint(x: 50, y: 0))
  }

  @Test("arc-length midpoint of an L-shape lies on the longer leg")
  func arcLengthMidpointOfLShape() {
    // 30pt horizontal + 100pt vertical = 130pt total. Midpoint at 65pt is
    // on the vertical leg starting at (30,0), so y=35.
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 30, y: 0),
        CGPoint(x: 30, y: 100),
      ],
      labelPosition: .zero
    )
    let midpoint = route.arcLengthMidpoint
    #expect(midpoint.x == 30)
    #expect(midpoint.y == 35)
  }

  @Test("arc-length midpoint of an empty route falls back to labelPosition")
  func arcLengthMidpointOfEmptyRoute() {
    let labelPosition = CGPoint(x: 7, y: 11)
    let route = PolicyCanvasEdgeRoute(points: [], labelPosition: labelPosition)
    // Watson R2 sev0 robustness guard: a degenerate empty-route can't
    // activate at (0, 0); it would land outside the stroke. Falling
    // back to labelPosition keeps the activation point on the edge's
    // visual anchor.
    #expect(route.arcLengthMidpoint == labelPosition)
  }

  @Test("arc-length midpoint of an all-coincident route falls back to labelPosition")
  func arcLengthMidpointOfCoincidentPoints() {
    let labelPosition = CGPoint(x: 33, y: 21)
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)],
      labelPosition: labelPosition
    )
    // When every point coincides the total length is zero; without the
    // guard the function returned (0, 0) via the trailing `?? .zero`.
    // Now it returns labelPosition so the activation point stays on
    // the edge's visual anchor.
    #expect(route.arcLengthMidpoint == labelPosition)
  }

  @Test("arc-length midpoint of a single-point route returns that point")
  func arcLengthMidpointOfSinglePoint() {
    let point = CGPoint(x: 42, y: 17)
    let route = PolicyCanvasEdgeRoute(points: [point], labelPosition: .zero)
    #expect(route.arcLengthMidpoint == point)
  }

  // Phase 3 (Watson R2 WCAG 2.3.3): the dash march advances at 12pt/sec at
  // 1x canvas zoom, but the apparent on-screen velocity scales linearly
  // with zoom. At 4x-8x zoom the apparent velocity would be 48-96pt/sec,
  // approaching the vestibular-trigger band for users on system Zoom who
  // do not have prefers-reduced-motion enabled. The clamp ensures
  // apparent velocity never exceeds 24pt/sec regardless of zoom level.
  @Test("dash march velocity stays at baseline below 2x zoom")
  func dashVelocityUnclampedBelow2x() {
    #expect(PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: 1) == 12)
    #expect(PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: 0.5) == 12)
    #expect(PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: 2) == 12)
  }

  @Test("dash march velocity is clamped at 4x and 8x zoom")
  func dashVelocityClampedAtFarZoom() {
    // At zoom 4, apparent should be capped at 24pt/sec -> effective 6.
    #expect(PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: 4) == 6)
    // At zoom 8, apparent capped at 24 -> effective 3.
    #expect(PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: 8) == 3)
  }

  @Test("dash march apparent velocity caps at 24pt/sec across zoom range")
  func dashApparentVelocityStaysWithinCap() {
    let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 1.5, 2, 2.5, 4, 8, 16]
    for zoom in zoomLevels {
      let effective = PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom: zoom)
      let apparent = effective * zoom
      #expect(
        apparent <= PolicyCanvasEdgeAnimation.maxApparentVelocityPointsPerSecond + 0.0001,
        "Apparent velocity \(apparent)pt/sec exceeded 24pt/sec cap at zoom \(zoom)"
      )
    }
  }

  // Phase 3 (Norman R2 deferred): the canvas applies `.scaleEffect` so a
  // [3,2] world dash renders at 0.75pt at zoom 0.25, aliasing to solid.
  // The scaling rule multiplies the pattern by 1/max(0.5, zoom) at and
  // below 1x so the on-screen dash period stays constant; at zoom >= 1
  // the world pattern is already at design size and passes through.
  @Test("dash pattern passes through unchanged at and above 1x zoom")
  func dashPatternUnchangedAtUnityZoom() {
    let error = PolicyCanvasEdgeKind.error.strokeDashPattern
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(error, canvasZoom: 1) == error)
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(error, canvasZoom: 2) == error)
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(error, canvasZoom: 4) == error)
  }

  @Test("dash pattern is scaled to keep on-screen size constant below 1x")
  func dashPatternScaledBelowUnity() {
    let error = PolicyCanvasEdgeKind.error.strokeDashPattern  // [3, 2]
    // At zoom 0.5: scale = 1/0.5 = 2 -> [6, 4]
    let halfZoom = PolicyCanvasEdgeAnimation.scaledDashPattern(error, canvasZoom: 0.5)
    #expect(halfZoom == [6, 4])
    // At zoom 0.25: clamp keeps divisor at 0.5 -> scale = 2 -> [6, 4]
    let quarterZoom = PolicyCanvasEdgeAnimation.scaledDashPattern(error, canvasZoom: 0.25)
    #expect(quarterZoom == [6, 4])
  }

  @Test("empty dash pattern stays empty regardless of zoom")
  func dashPatternEmptyAtAllZoom() {
    let flow = PolicyCanvasEdgeKind.flow.strokeDashPattern  // []
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(flow, canvasZoom: 0.25).isEmpty)
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(flow, canvasZoom: 1).isEmpty)
    #expect(PolicyCanvasEdgeAnimation.scaledDashPattern(flow, canvasZoom: 4).isEmpty)
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

  // Per-target Connect actions surface target node + port titles, capped at
  // the configured action-cap so the VoiceOver rotor stays usable. The
  // display name must let the user disambiguate between targets ("Risk score
  // event" vs "Context map event") instead of the prior silent first-hit.
  @Test("connect named targets carry node + port titles for the rotor")
  func connectNamedTargetsCarryNodeAndPortTitles() {
    let viewModel = PolicyCanvasViewModel.sample()
    let named = viewModel.accessibilityConnectableNamedTargets(
      fromNodeID: "policy-source"
    )
    #expect(!named.isEmpty)
    #expect(named.count <= PolicyCanvasViewModel.accessibilityConnectableTargetActionCap)

    let displayNames = named.map(\.displayName)
    for name in displayNames {
      // "<node title> <port title>" - both pieces are present so VO announces
      // both halves of the destination, not just the node.
      #expect(name.split(separator: " ").count >= 2)
    }

    // The first reachable target's endpoint matches the legacy first-hit, so
    // the rotor's first entry preserves the prior keyboard shortcut path.
    let legacy = viewModel.accessibilityConnectableTargets(fromNodeID: "policy-source")
    guard let firstLegacy = legacy.first, let firstNamed = named.first else {
      Issue.record("expected first connect target to exist")
      return
    }
    #expect(firstNamed.endpoint == firstLegacy)
  }

  // Cap enforcement: synthesize enough reachable inputs to exceed the cap and
  // confirm the named-targets list does not exceed it. The accessibility
  // rotor floor is sensitive to long lists; this is a discoverability cap,
  // not a routing cap.
  @Test("connect named targets respect the rotor cap")
  func connectNamedTargetsRespectRotorCap() {
    let viewModel = PolicyCanvasViewModel.sample()
    // Add enough fresh condition nodes (each contributes one `event` input
    // port) to push reachable targets past the cap. Position them on a fresh
    // row so the snap-to-grid de-collision doesn't merge into existing nodes.
    let cap = PolicyCanvasViewModel.accessibilityConnectableTargetActionCap
    let needed = cap + 2
    for index in 0..<needed {
      viewModel.createNode(
        kind: .condition,
        at: CGPoint(x: 1400 + CGFloat(index) * 220, y: 720)
      )
    }
    let named = viewModel.accessibilityConnectableNamedTargets(
      fromNodeID: "policy-source"
    )
    #expect(named.count == cap)
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

  // Escape / scenePhase / republish: `clearTransientGestureState()` must drop
  // every in-flight gesture slot (rubber-band preview, input highlight, group
  // highlight) and keep the `hasPendingEdge` presence-bit in sync with the
  // payload. Routing the rubber-band clear through `clearPendingEdge()`
  // guarantees the bit re-flips on Escape mid-drag.
  @Test("clear transient gesture state drops rubber-band, highlights, presence bit")
  func clearTransientGestureStateDropsAllSlots() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.beginPendingEdge(
      sourceNodeID: "policy-source",
      sourcePortID: "output-event"
    )
    viewModel.highlightedInput = PolicyCanvasPortEndpoint(
      nodeID: "risk-score",
      portID: "input-event",
      kind: .input
    )
    viewModel.highlightedGroupID = "group-evaluation"

    #expect(viewModel.pendingEdgePreview != nil)
    #expect(viewModel.hasPendingEdge)

    viewModel.clearTransientGestureState()

    #expect(viewModel.pendingEdgePreview == nil)
    #expect(!viewModel.hasPendingEdge)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }
}
